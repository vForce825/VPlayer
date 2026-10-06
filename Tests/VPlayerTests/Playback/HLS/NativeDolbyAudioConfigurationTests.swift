// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class NativeDolbyAudioConfigurationTests: XCTestCase {
    func testSelectedDolbyRawBoxAndCoreAudioCookieRepresentationsHaveSameSemanticFacts() throws {
        for codec in [AudioCodec.ac3, .eac3] {
            let box = configuration(codec)
            let raw = Data(box.dropFirst(8))
            let wire: [UInt8] = codec == .ac3 ? [0x61, 0x63, 0x2D, 0x33] : [0x65, 0x63, 0x2D, 0x33]
            let cookie = Data([0, 0, 0, 12, 0x66, 0x72, 0x6D, 0x61] + wire) + box
            let expected = try NativeDolbyAudioConfiguration.parse(cookie: box, codec: codec, sampleRate: 48_000)
            for bytes in [raw, box, cookie, cookie + Data([0, 0, 0, 8, 0, 0, 0, 0])] {
                XCTAssertEqual(try NativeDolbyAudioConfiguration.parse(cookie: bytes, codec: codec, sampleRate: 48_000), expected)
            }
            XCTAssertEqual(expected.profile, codec == .ac3 ? 8 : 16)
            XCTAssertEqual(expected.channelCount, 6)
            XCTAssertTrue(expected.matches(source(codec), observedChannelMask: 0x3F),
                "Absent original bytes still require the parsed selected bsid/rate/layout and independent service")
            XCTAssertTrue(expected.matches(source(codec, configuration: raw), observedChannelMask: 0x3F))
            XCTAssertTrue(expected.matches(source(codec, configuration: cookie), observedChannelMask: 0x3F))
        }
    }
    func testNativeMonoUsesCenterAndSameChannelCountCannotHideBackVersusSideChange() throws {
        for codec in [AudioCodec.ac3, .eac3] {
            let mono = try NativeDolbyAudioConfiguration.parse(cookie: configuration(codec, mode: 1, lfe: false), codec: codec, sampleRate: 48_000)
            XCTAssertTrue(mono.matches(source(codec, channels: 1, mask: 4), observedChannelMask: 4))
            XCTAssertFalse(mono.matches(source(codec, channels: 1, mask: 1), observedChannelMask: 1))
            let surround = try NativeDolbyAudioConfiguration.parse(cookie: configuration(codec), codec: codec, sampleRate: 48_000)
            XCTAssertTrue(surround.matches(source(codec, mask: 0x60F), observedChannelMask: 0x60F))
            XCTAssertFalse(surround.matches(source(codec, mask: 0x60F), observedChannelMask: 0x3F))
            XCTAssertFalse(surround.matches(source(codec, mask: 0x3F), observedChannelMask: 0x60F))
        }
    }
    func testActualProfileRateAndConfigurationMustMatchOriginalSourceFacts() throws {
        for codec in [AudioCodec.ac3, .eac3] {
            let bytes = configuration(codec)
            XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: bytes, codec: codec, sampleRate: 44_100),
                "Passing a caller rate into the existing parser cannot validate fscod")
            let value = try NativeDolbyAudioConfiguration.parse(cookie: bytes, codec: codec, sampleRate: 48_000)
            XCTAssertFalse(value.matches(source(codec, profile: codec == .ac3 ? 9 : 15), observedChannelMask: 0x3F))
            XCTAssertFalse(value.matches(source(codec, configuration: configuration(codec, bitrate: 11)), observedChannelMask: 0x3F))
            XCTAssertFalse(value.matches(source(codec, service: .associated), observedChannelMask: 0x3F))
        }
        XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: configuration(.eac3, fscod: 3), codec: .eac3, sampleRate: 24_000),
            "dec3 fscod3 alone cannot distinguish its half-rate")
        XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: configuration(.ac3, profile: 9), codec: .ac3, sampleRate: 48_000))
        XCTAssertEqual(try NativeDolbyAudioConfiguration.parse(cookie: configuration(.ac3, profile: 9), codec: .ac3, sampleRate: 24_000).sampleRate, 24_000)
    }
    func testMissingAmbiguousOrWrongCodecCookieDoesNotGrantNativeAdmission() throws {
        for codec in [AudioCodec.ac3, .eac3] {
            XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: Data(), codec: codec, sampleRate: 48_000))
            XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: Data([0, 0]), codec: codec, sampleRate: 48_000))
            XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: configuration(codec, mode: 0), codec: codec, sampleRate: 48_000))
            XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: configuration(codec, bsmod: 2), codec: codec, sampleRate: 48_000))
        }
        XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: configuration(.eac3), codec: .ac3, sampleRate: 48_000))
        XCTAssertThrowsError(try NativeDolbyAudioConfiguration.parse(cookie: configuration(.ac3), codec: .eac3, sampleRate: 48_000))
    }
    private func source(_ codec: AudioCodec, profile: Int32? = nil, channels: Int32 = 6, mask: UInt64 = 0x3F,
                        configuration: Data = Data(), service: HLSSourceAudioService = .independentMain) -> HLSSourceAudioFacts {
        .init(codec: codec, profile: profile ?? (codec == .ac3 ? 8 : 16), sampleRate: 48_000,
            channelCount: channels, channelMask: mask, decoderConfiguration: configuration,
            priming: .notSignaledPreserveTimestamps, service: service, formatValidated: true)
    }
    private func configuration(_ codec: AudioCodec, mode: UInt8 = 7, lfe: Bool = true,
                               fscod: UInt8 = 0, profile: UInt8? = nil, bsmod: UInt8 = 0, bitrate: UInt32 = 10) -> Data {
        if codec == .ac3 {
            let payload = UInt32(fscod) << 22 | UInt32(profile ?? 8) << 17 | UInt32(bsmod) << 14 |
                UInt32(mode) << 11 | UInt32(lfe ? 1 : 0) << 10 | bitrate << 5
            return Data([0, 0, 0, 11, 0x64, 0x61, 0x63, 0x33,
                UInt8((payload >> 16) & 255), UInt8((payload >> 8) & 255), UInt8(payload & 255)])
        }
        let payload = UInt32(fscod) << 22 | UInt32(profile ?? 16) << 17 | UInt32(bsmod) << 12 |
            UInt32(mode) << 9 | UInt32(lfe ? 1 : 0) << 8
        return Data([0, 0, 0, 13, 0x64, 0x65, 0x63, 0x33, UInt8((bitrate << 3) >> 8), UInt8((bitrate << 3) & 255),
            UInt8((payload >> 16) & 255), UInt8((payload >> 8) & 255), UInt8(payload & 255)])
    }
}
