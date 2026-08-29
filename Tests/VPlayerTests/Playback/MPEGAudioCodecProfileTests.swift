// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class MPEGAudioCodecProfileTests: XCTestCase {
    func testMPEGExactFrameLengthRejectsTrailingByte() throws {
        let valid = makeMPEGFrame(
            versionID: 3,
            layerBits: 1,
            bitrateIndex: 9,
            sampleRateIndex: 1,
            channelMode: 0,
            frameLength: 384
        )
        let source = makeSource(codec: .mp3, sampleRate: 48_000, channels: 2)
        let profile = try MPEGAudioCodecProfile(codec: .mp3)

        XCTAssertNoThrow(try profile.inspect(
            makeParsedFrame(valid, samples: 1_152, rate: 48_000, channels: 2),
            source: source
        ))
        XCTAssertThrowsError(try profile.inspect(
            makeParsedFrame(valid + Data([0]), samples: 1_152, rate: 48_000, channels: 2),
            source: source
        ))
    }

    func testProfilesProduceLayer1Layer2Layer3FormatIDsAndSampleCounts() throws {
        let cases: [(VPlayerPlayback.AudioCodec, UInt32, UInt32, Int, Int32,
                     AudioFormatID, Int32, UInt32)] = [
            (.mp1, 3, 3, 288, 48_000, kAudioFormatMPEGLayer1, 384, 384),
            (.mp2, 3, 2, 480, 48_000, kAudioFormatMPEGLayer2, 1_152, 1_152),
            (.mp3, 3, 1, 384, 48_000, kAudioFormatMPEGLayer3, 1_152, 0),
        ]

        for (codec, version, layer, length, rate, formatID, samples, framesPerPacket) in cases {
            let payload = makeMPEGFrame(
                versionID: version,
                layerBits: layer,
                bitrateIndex: 9,
                sampleRateIndex: 1,
                channelMode: 0,
                frameLength: length
            )
            let source = makeSource(codec: codec, sampleRate: rate, channels: 2)
            let inspected = try MPEGAudioCodecProfile(codec: codec).inspect(
                makeParsedFrame(payload, samples: samples, rate: rate, channels: 2),
                source: source
            )

            XCTAssertEqual(inspected.sampleCount, samples)
            XCTAssertEqual(inspected.systemFormat.formatID, formatID)
            XCTAssertEqual(inspected.systemFormat.framesPerPacket, framesPerPacket)
            XCTAssertNil(inspected.systemFormat.magicCookie)
        }
    }

    func testMPEG2And25Layer3Use576SamplesWhileMPEG1Uses1152() throws {
        let cases: [(UInt32, Int, Int32, Int32)] = [
            (3, 384, 48_000, 1_152),
            (2, 192, 24_000, 576),
            (0, 384, 12_000, 576),
        ]

        for (version, length, rate, samples) in cases {
            let payload = makeMPEGFrame(
                versionID: version,
                layerBits: 1,
                bitrateIndex: version == 3 ? 9 : 8,
                sampleRateIndex: 1,
                channelMode: 0,
                frameLength: length
            )
            let source = makeSource(codec: .mp3, sampleRate: rate, channels: 2)
            let inspected = try MPEGAudioCodecProfile(codec: .mp3).inspect(
                makeParsedFrame(payload, samples: samples, rate: rate, channels: 2),
                source: source
            )

            XCTAssertEqual(inspected.sampleCount, samples)
            XCTAssertEqual(inspected.systemFormat.framesPerPacket, 0)
        }
    }

    func testProfileRejectsHeaderParserDescriptorAndFrameLengthMismatch() throws {
        let valid = makeMPEGFrame(
            versionID: 3,
            layerBits: 1,
            bitrateIndex: 9,
            sampleRateIndex: 1,
            channelMode: 0,
            frameLength: 384
        )
        let source = makeSource(codec: .mp3, sampleRate: 48_000, channels: 2)
        let profile = try MPEGAudioCodecProfile(codec: .mp3)

        XCTAssertThrowsError(try profile.inspect(
            makeParsedFrame(valid, samples: 576, rate: 48_000, channels: 2),
            source: source
        ))
        XCTAssertThrowsError(try profile.inspect(
            makeParsedFrame(valid, samples: 1_152, rate: 44_100, channels: 2),
            source: source
        ))
        XCTAssertThrowsError(try profile.inspect(
            makeParsedFrame(valid, samples: 1_152, rate: 48_000, channels: 1),
            source: source
        ))
        let wrongDescriptorRate = makeSource(codec: .mp3, sampleRate: 44_100, channels: 2)
        XCTAssertThrowsError(try profile.inspect(
            makeParsedFrame(valid, samples: 1_152, rate: 48_000, channels: 2),
            source: wrongDescriptorRate
        ))
        XCTAssertThrowsError(try MPEGAudioCodecProfile(codec: .mp2).inspect(
            makeParsedFrame(valid, samples: 1_152, rate: 48_000, channels: 2),
            source: makeSource(codec: .mp2, sampleRate: 48_000, channels: 2)
        ))
        XCTAssertThrowsError(try profile.inspect(
            makeParsedFrame(Data(valid.dropLast()), samples: 1_152, rate: 48_000, channels: 2),
            source: source
        ))
        XCTAssertThrowsError(try profile.inspect(
            makeParsedFrame(valid + Data([0]), samples: 1_152, rate: 48_000, channels: 2),
            source: source
        ))
        var freeBitrate = valid
        freeBitrate[2] &= 0x0F
        XCTAssertThrowsError(try profile.inspect(
            makeParsedFrame(freeBitrate, samples: 1_152, rate: 48_000, channels: 2),
            source: source
        ))
    }

    private func makeMPEGFrame(
        versionID: UInt32,
        layerBits: UInt32,
        bitrateIndex: UInt32,
        sampleRateIndex: UInt32,
        channelMode: UInt32,
        frameLength: Int
    ) -> Data {
        let header = UInt32(0x7FF) << 21
            | versionID << 19
            | layerBits << 17
            | 1 << 16
            | bitrateIndex << 12
            | sampleRateIndex << 10
            | channelMode << 6
        var result = Data([
            UInt8((header >> 24) & 0xFF),
            UInt8((header >> 16) & 0xFF),
            UInt8((header >> 8) & 0xFF),
            UInt8(header & 0xFF),
        ])
        result.append(Data(repeating: 0xA5, count: frameLength - 4))
        return result
    }

    private func makeParsedFrame(
        _ payload: Data,
        samples: Int32,
        rate: Int32,
        channels: Int32
    ) -> FramedCompressedAudioFrame {
        FramedCompressedAudioFrame(
            payload: payload,
            presentationTimeStamp: .zero,
            parserSampleCount: samples,
            parserSampleRate: rate,
            parserChannelLayout: AudioChannelLayout(
                channelCount: channels,
                nativeMask: channels == 2 ? 3 : 4
            ),
            containerMarkedCorrupt: false
        )
    }

    private func makeSource(
        codec: VPlayerPlayback.AudioCodec,
        sampleRate: Int32,
        channels: Int32
    ) -> AudioTrackDescriptor {
        AudioTrackDescriptor(
            streamIndex: 1,
            codec: codec,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: sampleRate,
            channelLayout: AudioChannelLayout(
                channelCount: channels,
                nativeMask: channels == 2 ? 3 : 4
            ),
            extradata: Data()
        )
    }
}
