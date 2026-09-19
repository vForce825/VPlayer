// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class SupportedAudioInputDomainTests: XCTestCase {
    func testAC3DomainIncludesEveryBsidAcceptedByTheProductionParser() {
        XCTAssertEqual(Set(SupportedAudioInputDomain.ac3HeaderEntries.map(\.bsid)), Set(UInt8(0)...UInt8(10)))
        XCTAssertEqual(SupportedAudioInputDomain.ac3HeaderEntries.count, 1_254)
    }

    func testApprovedCodecsAreTheRegistrysExactDomain() {
        XCTAssertEqual(
            SupportedAudioInputDomain.approvedCodecs,
            AudioCodecProfileRegistry.approvedCodecs
        )
        XCTAssertEqual(
            SupportedAudioInputDomain.approvedCodecs,
            [.aac, .mp1, .mp2, .mp3, .ac3, .eac3]
        )
    }

    func testAACRawProfilesAndADTSAreInspectedByTheRealProfile() throws {
        let rawCases: [(Data, AudioCodecProfileID, Int32, Int32)] = [
            (Data([0x11, 0x90]), .aacLC, 48_000, 1_024),
            (Data([0x2B, 0x11, 0x88, 0x00]), .heAACv1, 48_000, 2_048),
            (Data([0xEB, 0x09, 0x88, 0x00]), .heAACv2, 48_000, 2_048),
            (makeExplicitAACLCASC(sampleRate: 12_345), .aacLC, 12_345, 1_024),
        ]
        for (asc, profileID, rate, sampleCount) in rawCases {
            let facts = try inspect(
                codec: .aac,
                sampleRate: rate,
                channels: 2,
                extradata: asc,
                payload: Data([0x21])
            )
            XCTAssertEqual(facts.codec, .aac)
            XCTAssertEqual(facts.framing, .rawAAC)
            XCTAssertEqual(facts.profileID, profileID)
            XCTAssertEqual(facts.sampleRate, rate)
            XCTAssertEqual(facts.sampleCount, sampleCount)
            XCTAssertEqual(facts.channelCount, 2)
        }

        XCTAssertEqual(SupportedAudioInputDomain.aacRawKinds, [.aacLC, .heAACv1, .heAACv2])
        XCTAssertEqual(SupportedAudioInputDomain.aacExplicitSampleRateRange, 1...0xFF_FFFF)
        for (rateIndex, rate) in SupportedAudioInputDomain.aacIndexedSampleRates.enumerated() {
            let raw = try inspect(
                codec: .aac,
                sampleRate: rate,
                channels: 2,
                extradata: makeAACLCASC(rateIndex: rateIndex),
                payload: Data([0x31])
            )
            XCTAssertEqual(raw.profileID, .aacLC, "raw rate=\(rate)")
            XCTAssertEqual(raw.sampleRate, rate, "raw rate=\(rate)")

            let adts = try inspect(
                codec: .aac,
                sampleRate: rate,
                channels: 2,
                extradata: Data(),
                payload: makeADTSFrame(rateIndex: rateIndex, channels: 2)
            )
            XCTAssertEqual(adts.codec, .aac, "ADTS rate=\(rate)")
            XCTAssertEqual(adts.framing, .adts, "ADTS rate=\(rate)")
            XCTAssertEqual(adts.profileID, .aacLC, "ADTS rate=\(rate)")
            XCTAssertEqual(adts.sampleRate, rate, "ADTS rate=\(rate)")
            XCTAssertEqual(adts.sampleCount, 1_024, "ADTS rate=\(rate)")
            XCTAssertEqual(adts.channelCount, 2, "ADTS rate=\(rate)")
        }
    }

    func testMPEGLayersAndLowRateVersionsUseRealHeaderInspection() throws {
        XCTAssertEqual(SupportedAudioInputDomain.mpegHeaderEntries.count, 27)
        for entry in SupportedAudioInputDomain.mpegHeaderEntries {
            let facts = try inspect(
                codec: entry.codec,
                sampleRate: entry.sampleRate,
                channels: 2,
                extradata: Data(),
                payload: makeMPEGFrame(
                    versionBits: entry.versionBits,
                    layerBits: entry.layerBits,
                    sampleRateIndex: entry.sampleRateIndex,
                    sampleRate: entry.sampleRate,
                    bitrate: entry.referenceBitrate
                ),
                parserSampleCount: entry.sampleCount
            )
            let profileID: AudioCodecProfileID = switch entry.codec {
            case .mp1: .mpegLayer1
            case .mp2: .mpegLayer2
            case .mp3: .mpegLayer3
            default: preconditionFailure("生产MPEG域只能包含三层")
            }
            XCTAssertEqual(facts.codec, entry.codec)
            XCTAssertEqual(facts.framing, .ffmpegParser)
            XCTAssertEqual(facts.profileID, profileID)
            XCTAssertEqual(facts.sampleRate, entry.sampleRate)
            XCTAssertEqual(facts.sampleCount, entry.sampleCount)
            XCTAssertEqual(facts.channelCount, 2)
        }
    }

    func testAC3AndEAC3LowRatesRemainInTheRealProfileDomain() throws {
        XCTAssertEqual(SupportedAudioInputDomain.ac3HeaderEntries.count, 1_254)
        for entry in SupportedAudioInputDomain.ac3HeaderEntries {
            let ac3 = try inspect(
                codec: .ac3,
                sampleRate: entry.sampleRate,
                channels: 2,
                extradata: Data(),
                payload: AssemblerTestFixtures.syntheticAC3Frame(
                    fscod: entry.fscod,
                    frmsizecod: entry.frmsizecod,
                    bsid: entry.bsid,
                    acmod: 2,
                    lfeon: false
                ),
                parserSampleCount: 1_536
            )
            XCTAssertEqual(ac3.profileID, .ac3)
            XCTAssertEqual(ac3.sampleRate, entry.sampleRate)
            XCTAssertEqual(ac3.sampleCount, 1_536)
        }

        XCTAssertEqual(SupportedAudioInputDomain.eac3HeaderEntries.count, 15)
        for entry in SupportedAudioInputDomain.eac3HeaderEntries {
            let eac3 = try inspect(
                codec: .eac3,
                sampleRate: entry.sampleRate,
                channels: 2,
                extradata: Data(),
                payload: EAC3SemanticFixture.make(
                    sampleRate: entry.sampleRate,
                    blockCount: entry.blockCount,
                    streamType: 0,
                    substreamID: 0,
                    bsid: 16,
                    bsmod: 0,
                    audioCodingMode: 2,
                    hasLFE: false,
                    hasInfoMetadata: true,
                    hasJOC: false
                ),
                parserSampleCount: entry.sampleCount
            )
            XCTAssertEqual(eac3.profileID, .eac3)
            XCTAssertEqual(eac3.sampleRate, entry.sampleRate)
            XCTAssertEqual(eac3.sampleCount, entry.sampleCount)
        }
    }

    func testProfileAndParserRejectionsPassThroughWithoutHLSOverrides() throws {
        XCTAssertThrowsError(try inspect(
            codec: .aac,
            sampleRate: 48_000,
            channels: 2,
            extradata: Data([0x0B, 0x90]),
            payload: Data([0x21])
        ), "不受支持的 AAC profile 必须由真实 ASC parser 拒绝")

        let mp3 = makeMPEGFrame(
            versionBits: 3,
            layerBits: 1,
            sampleRateIndex: 1,
            sampleRate: 48_000,
            bitrate: 32_000
        )
        XCTAssertThrowsError(try inspect(
            codec: .mp2,
            sampleRate: 48_000,
            channels: 2,
            extradata: Data(),
            payload: mp3,
            parserSampleCount: 1_152
        ), "codec/profile 与 MPEG layer 不符时必须由真实 header parser 拒绝")

        XCTAssertThrowsError(try inspect(
            codec: .eac3,
            sampleRate: 48_000,
            channels: 6,
            nativeMask: 0x3F,
            extradata: Data(),
            payload: EAC3SemanticFixture.make(
                sampleRate: 48_000,
                blockCount: 6,
                streamType: 0,
                substreamID: 0,
                bsid: 16,
                bsmod: 0,
                audioCodingMode: 2,
                hasLFE: false,
                hasInfoMetadata: true,
                hasJOC: false
            ),
            parserSampleCount: 1_024
        ), "非法 E-AC-3 block sample count 必须由真实 profile 拒绝")
    }

    private func inspect(
        codec: AudioCodec,
        sampleRate: Int32,
        channels: Int32,
        nativeMask: UInt64? = 3,
        extradata: Data,
        payload: Data,
        parserSampleCount: Int32? = nil
    ) throws -> SupportedAudioInputFacts {
        let source = AudioTrackDescriptor(
            streamIndex: 1,
            codec: codec,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: sampleRate,
            channelLayout: AudioChannelLayout(channelCount: channels, nativeMask: nativeMask),
            extradata: extradata
        )
        return try SupportedAudioInputDomain.inspect(
            FramedCompressedAudioFrame(
                payload: payload,
                presentationTimeStamp: .zero,
                parserSampleCount: parserSampleCount,
                parserSampleRate: parserSampleCount == nil ? nil : sampleRate,
                parserChannelLayout: parserSampleCount == nil
                    ? nil
                    : AudioChannelLayout(channelCount: channels, nativeMask: nativeMask),
                containerMarkedCorrupt: false
            ),
            source: source
        )
    }

    private func makeExplicitAACLCASC(sampleRate: Int32) -> Data {
        var writer = TestBitWriter()
        writer.write(2, bitCount: 5)
        writer.write(15, bitCount: 4)
        writer.write(UInt32(sampleRate), bitCount: 24)
        writer.write(2, bitCount: 4)
        writer.write(0, bitCount: 3)
        return writer.data
    }

    private func makeAACLCASC(rateIndex: Int) -> Data {
        Data([
            UInt8((2 << 3) | (rateIndex >> 1)),
            UInt8(((rateIndex & 1) << 7) | (2 << 3)),
        ])
    }

    private func makeADTSFrame(rateIndex: Int, channels: UInt8) -> Data {
        let payload = Data([0x51, 0x52])
        let length = payload.count + 7
        return Data([
            0xFF,
            0xF1,
            0x40 | UInt8(rateIndex << 2) | (channels >> 2),
            (channels & 3) << 6 | UInt8((length >> 11) & 3),
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 7) << 5) | 0x1F,
            0xFC,
        ]) + payload
    }

    private func makeMPEGFrame(
        versionBits: UInt32,
        layerBits: UInt32,
        sampleRateIndex: UInt32,
        sampleRate: Int32,
        bitrate: Int
    ) -> Data {
        let frameLength: Int
        switch layerBits {
        case 3:
            frameLength = 12 * bitrate / Int(sampleRate) * 4
        case 2:
            frameLength = 144 * bitrate / Int(sampleRate)
        case 1:
            frameLength = (versionBits == 3 ? 144 : 72) * bitrate / Int(sampleRate)
        default:
            preconditionFailure("测试只构造 MPEG Layer I/II/III")
        }
        let header = UInt32(0x7FF) << 21
            | versionBits << 19
            | layerBits << 17
            | 1 << 16
            | 1 << 12
            | sampleRateIndex << 10
        var result = Data([
            UInt8((header >> 24) & 0xFF),
            UInt8((header >> 16) & 0xFF),
            UInt8((header >> 8) & 0xFF),
            UInt8(header & 0xFF),
        ])
        result.append(Data(repeating: 0xA5, count: frameLength - 4))
        return result
    }

}

private struct TestBitWriter {
    private(set) var data = Data()
    private var bitOffset = 0

    mutating func write(_ value: UInt32, bitCount: Int) {
        for shift in stride(from: bitCount - 1, through: 0, by: -1) {
            if bitOffset % 8 == 0 { data.append(0) }
            let bit = UInt8((value >> UInt32(shift)) & 1)
            data[data.index(before: data.endIndex)] |= bit << UInt8(7 - bitOffset % 8)
            bitOffset += 1
        }
    }
}
