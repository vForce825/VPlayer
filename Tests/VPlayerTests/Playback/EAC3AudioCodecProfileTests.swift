// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class EAC3AudioCodecProfileTests: XCTestCase {
    func testEAC3Retains256512768And1536SampleBlockCounts() throws {
        let source = AudioTrackDescriptor(
            streamIndex: 1,
            codec: .eac3,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: 6, nativeMask: 0x3F),
            extradata: Data()
        )
        let profile = EAC3AudioCodecProfile()

        for samples: Int32 in [256, 512, 768, 1_536] {
            let inspected = try profile.inspect(FramedCompressedAudioFrame(
                payload: makeEAC3Frame(byteCount: 8),
                presentationTimeStamp: .zero,
                parserSampleCount: samples,
                parserSampleRate: 48_000,
                parserChannelLayout: AudioChannelLayout(channelCount: 6, nativeMask: 0x3F),
                containerMarkedCorrupt: false
            ), source: source)

            XCTAssertEqual(inspected.sampleCount, samples)
            XCTAssertEqual(inspected.systemFormat.profileID, .eac3)
            XCTAssertEqual(inspected.systemFormat.formatID, kAudioFormatEnhancedAC3)
            XCTAssertEqual(inspected.systemFormat.framesPerPacket, 0)
        }

        XCTAssertThrowsError(try profile.inspect(FramedCompressedAudioFrame(
            payload: makeEAC3Frame(byteCount: 8),
            presentationTimeStamp: .zero,
            parserSampleCount: 1_024,
            parserSampleRate: 48_000,
            parserChannelLayout: AudioChannelLayout(channelCount: 6, nativeMask: 0x3F),
            containerMarkedCorrupt: false
        ), source: source))
    }

    func testEAC3HeaderLengthMustEqualPayloadLength() throws {
        let source = AudioTrackDescriptor(
            streamIndex: 1,
            codec: .eac3,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
            extradata: Data()
        )
        let profile = EAC3AudioCodecProfile()
        let valid = makeEAC3Frame(byteCount: 8)
        let parsed: (Data) -> FramedCompressedAudioFrame = { payload in
            FramedCompressedAudioFrame(
                payload: payload,
                presentationTimeStamp: .zero,
                parserSampleCount: 1_536,
                parserSampleRate: 48_000,
                parserChannelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
                containerMarkedCorrupt: false
            )
        }

        XCTAssertNoThrow(try profile.inspect(parsed(valid), source: source))
        XCTAssertThrowsError(try profile.inspect(parsed(Data(valid.dropLast())), source: source))
        XCTAssertThrowsError(try profile.inspect(parsed(valid + Data([0x00])), source: source))
    }

    private func makeEAC3Frame(byteCount: Int) -> Data {
        precondition(byteCount >= 4 && byteCount <= 4_096 && byteCount.isMultiple(of: 2))
        let frameSizeCode = byteCount / 2 - 1
        return Data([
            0x0B,
            0x77,
            UInt8((frameSizeCode >> 8) & 0x07),
            UInt8(frameSizeCode & 0xFF),
        ]) + Data(repeating: 0xA5, count: byteCount - 4)
    }
}
