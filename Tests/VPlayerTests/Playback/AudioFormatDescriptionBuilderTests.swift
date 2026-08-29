// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class AudioFormatDescriptionBuilderTests: XCTestCase {
    func testBuilderUsesCanonicalSystemFormatWithoutCodecSwitch() throws {
        let format = SystemCompressedAudioFormat(
            profileID: .mpegLayer1,
            codec: .aac,
            formatID: kAudioFormatMPEGLayer1,
            sampleRate: 32_000,
            channelCount: 2,
            framesPerPacket: 384,
            layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
            magicCookie: nil
        )

        let built = try AudioFormatDescriptionBuilder.make(format)
        let stream = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(built.description)?.pointee
        )

        XCTAssertEqual(stream.mFormatID, kAudioFormatMPEGLayer1)
        XCTAssertEqual(stream.mSampleRate, 32_000)
        XCTAssertEqual(stream.mChannelsPerFrame, 2)
        XCTAssertEqual(stream.mFramesPerPacket, 384)
        XCTAssertNil(try copiedMagicCookie(built.description))
    }

    func testBuilderPreservesNamedTagBitmapAndDiscreteLayoutSemantics() throws {
        let named = try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: .ac3,
            codec: .ac3,
            formatID: kAudioFormatAC3,
            sampleRate: 48_000,
            channelCount: 6,
            framesPerPacket: 1_536,
            layout: .tag(
                kAudioChannelLayoutTag_MPEG_5_1_A,
                equivalentBitmap: AudioChannelBitmap(rawValue: 0x3F)
            ),
            magicCookie: nil
        ))
        let bitmap = try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: .aacLC,
            codec: .aac,
            formatID: kAudioFormatMPEG4AAC,
            sampleRate: 48_000,
            channelCount: 2,
            framesPerPacket: 1_024,
            layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
            magicCookie: Data([0x11, 0x90])
        ))
        let discrete = try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: .mpegLayer2,
            codec: .mp2,
            formatID: kAudioFormatMPEGLayer2,
            sampleRate: 48_000,
            channelCount: 3,
            framesPerPacket: 1_152,
            layout: .discrete(3),
            magicCookie: nil
        ))

        let namedLayout = try copiedLayout(named.description)
        XCTAssertEqual(namedLayout.mChannelLayoutTag, kAudioChannelLayoutTag_MPEG_5_1_A)
        XCTAssertEqual(namedLayout.mChannelBitmap.rawValue, 0)
        let bitmapLayout = try copiedLayout(bitmap.description)
        XCTAssertEqual(bitmapLayout.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelBitmap)
        XCTAssertEqual(bitmapLayout.mChannelBitmap.rawValue, 3)
        let discreteLayout = try copiedLayout(discrete.description)
        XCTAssertEqual(discreteLayout.mChannelLayoutTag, kAudioChannelLayoutTag_DiscreteInOrder | 3)
        XCTAssertEqual(discreteLayout.mChannelBitmap.rawValue, 0)
    }

    func testBuilderRejectsInvalidSampleRateChannelCountAndLayout() {
        let valid = SystemCompressedAudioFormat(
            profileID: .aacLC,
            codec: .aac,
            formatID: kAudioFormatMPEG4AAC,
            sampleRate: 48_000,
            channelCount: 2,
            framesPerPacket: 1_024,
            layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
            magicCookie: Data([0x11, 0x90])
        )

        XCTAssertThrowsError(try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: valid.profileID, codec: valid.codec, formatID: valid.formatID,
            sampleRate: 0, channelCount: valid.channelCount,
            framesPerPacket: valid.framesPerPacket, layout: valid.layout,
            magicCookie: valid.magicCookie
        )))
        XCTAssertThrowsError(try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: valid.profileID, codec: valid.codec, formatID: valid.formatID,
            sampleRate: valid.sampleRate, channelCount: 0,
            framesPerPacket: valid.framesPerPacket, layout: .discrete(0),
            magicCookie: valid.magicCookie
        )))
        XCTAssertThrowsError(try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: valid.profileID, codec: valid.codec, formatID: valid.formatID,
            sampleRate: valid.sampleRate, channelCount: 2,
            framesPerPacket: valid.framesPerPacket,
            layout: .bitmap(AudioChannelBitmap(rawValue: 1)), magicCookie: valid.magicCookie
        )))
        XCTAssertThrowsError(try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: valid.profileID, codec: valid.codec, formatID: valid.formatID,
            sampleRate: valid.sampleRate, channelCount: 2,
            framesPerPacket: valid.framesPerPacket, layout: .discrete(1),
            magicCookie: valid.magicCookie
        )))
        XCTAssertThrowsError(try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: valid.profileID, codec: valid.codec, formatID: valid.formatID,
            sampleRate: valid.sampleRate, channelCount: 1,
            framesPerPacket: valid.framesPerPacket,
            layout: .tag(kAudioChannelLayoutTag_Stereo,
                         equivalentBitmap: AudioChannelBitmap(rawValue: 3)),
            magicCookie: valid.magicCookie
        )))
        XCTAssertThrowsError(try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: valid.profileID, codec: valid.codec, formatID: valid.formatID,
            sampleRate: valid.sampleRate, channelCount: 6,
            framesPerPacket: valid.framesPerPacket,
            layout: .tag(kAudioChannelLayoutTag_Stereo,
                         equivalentBitmap: AudioChannelBitmap(rawValue: 0x3F)),
            magicCookie: valid.magicCookie
        )))
    }

    private func copiedLayout(
        _ format: CMAudioFormatDescription
    ) throws -> AudioToolbox.AudioChannelLayout {
        var size = 0
        return try XCTUnwrap(
            CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size)?.pointee
        )
    }

    private func copiedMagicCookie(_ format: CMAudioFormatDescription) throws -> Data? {
        var size = 0
        guard let pointer = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size) else {
            XCTAssertEqual(size, 0)
            return nil
        }
        return Data(bytes: pointer, count: size)
    }
}
