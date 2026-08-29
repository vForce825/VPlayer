// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class AACAudioCodecProfileTests: XCTestCase {
    func testRawAACAcceptsExactlyOneMiBAndRejectsOneByteMore() throws {
        let source = makeSource(
            sampleRate: 48_000,
            channels: 2,
            extradata: Data([0x11, 0x90])
        )
        let profile = try AACAudioCodecProfile(source: source)

        XCTAssertNoThrow(try profile.inspect(
            makeFrame(Data(repeating: 0xA5, count: 1 * 1_024 * 1_024)),
            source: source
        ))
        XCTAssertThrowsError(try profile.inspect(
            makeFrame(Data(repeating: 0xA5, count: 1 * 1_024 * 1_024 + 1)),
            source: source
        ))
    }

    func testLCASCBuildsAACFormatWith1024FramesAndExactASC() throws {
        let asc = Data([0x11, 0x90])
        let source = makeSource(sampleRate: 48_000, channels: 2, extradata: asc)
        let inspected = try AACAudioCodecProfile(source: source).inspect(
            makeFrame(Data([0x01, 0x02, 0x03])), source: source
        )

        XCTAssertEqual(inspected.payload, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(inspected.sampleCount, 1_024)
        XCTAssertEqual(inspected.systemFormat.profileID, .aacLC)
        XCTAssertEqual(inspected.systemFormat.formatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(inspected.systemFormat.sampleRate, 48_000)
        XCTAssertEqual(inspected.systemFormat.channelCount, 2)
        XCTAssertEqual(inspected.systemFormat.framesPerPacket, 1_024)
        XCTAssertEqual(inspected.systemFormat.magicCookie, asc)

        let explicitFrequencyASC = Data([0x17, 0x80, 0x5D, 0xC0, 0x10])
        let explicitSource = makeSource(
            sampleRate: 48_000,
            channels: 2,
            extradata: explicitFrequencyASC
        )
        let explicit = try AACAudioCodecProfile(source: explicitSource).inspect(
            makeFrame(Data([0x04])), source: explicitSource
        )
        XCTAssertEqual(explicit.systemFormat.sampleRate, 48_000)
        XCTAssertEqual(explicit.systemFormat.magicCookie, explicitFrequencyASC)
    }

    func testExplicitSBRASCBuildsHEAACFormatWith2048FramesAndOutputRate() throws {
        let asc = Data([0x2B, 0x11, 0x88, 0x00])
        let source = makeSource(sampleRate: 48_000, channels: 2, extradata: asc)
        let inspected = try AACAudioCodecProfile(source: source).inspect(
            makeFrame(Data([0x21, 0x22])), source: source
        )

        XCTAssertEqual(inspected.sampleCount, 2_048)
        XCTAssertEqual(inspected.systemFormat.profileID, .heAACv1)
        XCTAssertEqual(inspected.systemFormat.formatID, kAudioFormatMPEG4AAC_HE)
        XCTAssertEqual(inspected.systemFormat.sampleRate, 48_000)
        XCTAssertEqual(inspected.systemFormat.channelCount, 2)
        XCTAssertEqual(inspected.systemFormat.framesPerPacket, 2_048)
        XCTAssertEqual(inspected.systemFormat.magicCookie, asc)
    }

    func testExplicitPSASCBuildsHEAACV2FormatWith2048FramesAndStereoOutput() throws {
        let asc = Data([0xEB, 0x09, 0x88, 0x00])
        let source = makeSource(sampleRate: 48_000, channels: 2, extradata: asc)
        let inspected = try AACAudioCodecProfile(source: source).inspect(
            makeFrame(Data([0x31, 0x32])), source: source
        )

        XCTAssertEqual(inspected.sampleCount, 2_048)
        XCTAssertEqual(inspected.systemFormat.profileID, .heAACv2)
        XCTAssertEqual(inspected.systemFormat.formatID, kAudioFormatMPEG4AAC_HE_V2)
        XCTAssertEqual(inspected.systemFormat.sampleRate, 48_000)
        XCTAssertEqual(inspected.systemFormat.channelCount, 2)
        XCTAssertEqual(inspected.systemFormat.framesPerPacket, 2_048)
        XCTAssertEqual(inspected.systemFormat.magicCookie, asc)
    }

    func testExplicitSBRASCRejectsNonDualRateConfiguration() {
        let asc = Data([0x2A, 0x91, 0x88, 0x00])
        let source = makeSource(sampleRate: 48_000, channels: 2, extradata: asc)

        XCTAssertThrowsError(try AACAudioCodecProfile(source: source).inspect(
            makeFrame(Data([0x21, 0x22])),
            source: source
        ))
    }

    func testExplicitPSASCRejectsNonDualRateConfiguration() {
        let asc = Data([0xEA, 0x89, 0x88, 0x00])
        let source = makeSource(sampleRate: 48_000, channels: 2, extradata: asc)

        XCTAssertThrowsError(try AACAudioCodecProfile(source: source).inspect(
            makeFrame(Data([0x31, 0x32])),
            source: source
        ))
    }

    func testAACRejectsTruncatedOversizedUnsupported960FrameAndDescriptorMismatchASC() throws {
        let validPayload = makeFrame(Data([0x41]))
        let rejectedASCs = [
            Data([0x2B]),
            Data(repeating: 0, count: 65),
            Data([0x0B, 0x90]),
            Data([0x11, 0x94]),
            Data([0x11, 0x90, 0x56, 0xE5, 0x98]),
        ]
        for asc in rejectedASCs {
            let source = makeSource(sampleRate: 48_000, channels: 2, extradata: asc)
            XCTAssertThrowsError(try AACAudioCodecProfile(source: source).inspect(
                validPayload,
                source: source
            ), "unexpectedly accepted ASC \(asc as NSData)")
        }

        let asc = Data([0x11, 0x90])
        let wrongRate = makeSource(sampleRate: 44_100, channels: 2, extradata: asc)
        XCTAssertThrowsError(try AACAudioCodecProfile(source: wrongRate).inspect(
            validPayload,
            source: wrongRate
        ))
        let wrongChannels = makeSource(sampleRate: 48_000, channels: 1, extradata: asc)
        XCTAssertThrowsError(try AACAudioCodecProfile(source: wrongChannels).inspect(
            validPayload,
            source: wrongChannels
        ))

        let rawSource = makeSource(sampleRate: 48_000, channels: 2, extradata: asc)
        XCTAssertThrowsError(try AACAudioCodecProfile(source: rawSource).inspect(
            makeFrame(Data([0x56, 0xE0, 0x00])),
            source: rawSource
        ))
    }

    func testADTSNeverGuessesHEAAC() throws {
        let payload = Data([0x51, 0x52, 0x53])
        let source = makeSource(sampleRate: 24_000, channels: 2, extradata: Data())
        let inspected = try AACAudioCodecProfile(source: source).inspect(
            makeFrame(makeADTSFrame(payload: payload, frequencyIndex: 6, channels: 2)),
            source: source
        )

        XCTAssertEqual(inspected.payload, payload)
        XCTAssertEqual(inspected.sampleCount, 1_024)
        XCTAssertEqual(inspected.systemFormat.profileID, .aacLC)
        XCTAssertEqual(inspected.systemFormat.formatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(inspected.systemFormat.sampleRate, 24_000)
        XCTAssertEqual(inspected.systemFormat.framesPerPacket, 1_024)
        XCTAssertEqual(inspected.systemFormat.magicCookie, Data([0x13, 0x10]))
    }

    func testADTSTrailingByteIsRejected() throws {
        let source = makeSource(sampleRate: 48_000, channels: 2, extradata: Data())
        let valid = makeADTSFrame(
            payload: Data([0x21, 0x22]),
            frequencyIndex: 3,
            channels: 2
        )

        XCTAssertNoThrow(try AACAudioCodecProfile(source: source).inspect(
            makeFrame(valid),
            source: source
        ))
        XCTAssertThrowsError(try AACAudioCodecProfile(source: source).inspect(
            makeFrame(valid + Data([0x00])),
            source: source
        ))
    }

    private func makeSource(
        sampleRate: Int32,
        channels: Int32,
        extradata: Data
    ) -> AudioTrackDescriptor {
        AudioTrackDescriptor(
            streamIndex: 1,
            codec: .aac,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: sampleRate,
            channelLayout: AudioChannelLayout(
                channelCount: channels,
                nativeMask: channels == 2 ? 3 : 4
            ),
            extradata: extradata
        )
    }

    private func makeFrame(_ payload: Data) -> FramedCompressedAudioFrame {
        FramedCompressedAudioFrame(
            payload: payload,
            presentationTimeStamp: .zero,
            parserSampleCount: nil,
            parserSampleRate: nil,
            parserChannelLayout: nil,
            containerMarkedCorrupt: false
        )
    }

    private func makeADTSFrame(
        payload: Data,
        frequencyIndex: UInt8,
        channels: UInt8
    ) -> Data {
        let length = payload.count + 7
        let header = Data([
            0xFF,
            0xF1,
            0x40 | (frequencyIndex << 2) | (channels >> 2),
            (channels & 3) << 6 | UInt8((length >> 11) & 3),
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 7) << 5) | 0x1F,
            0xFC,
        ])
        return header + payload
    }
}
