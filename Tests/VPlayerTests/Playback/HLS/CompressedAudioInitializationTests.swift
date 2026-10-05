// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class CompressedAudioInitializationTests: XCTestCase {
    func testEmittedAACUsesExactASCDespiteConventionalSampleEntryFields() throws {
        for asc in [Data([0x12, 0x08]), Data([0x12, 0x30]), Data([0x11, 0x90])] {
            let parsed = try AudioSpecificConfig.parse(asc)
            let facts = try FMP4CompressedAudioInspection.initialization(Self.initialization(
                entry: "mp4a", children: Self.box("esds", Data(repeating: 0, count: 4)
                    + parsed.coreAudioMagicCookie), timescale: parsed.outputSampleRate))
            XCTAssertEqual(facts.sampleEntry, 0x6d703461)
            XCTAssertEqual(facts.decoderConfiguration, asc)
            XCTAssertEqual(facts.timescale, parsed.outputSampleRate)
            XCTAssertEqual(facts.sampleEntryChannelCount, 2)
            XCTAssertEqual(facts.sampleEntrySampleRate, 48_000)
        }
    }
    func testActualDolbyConfigurationAndExactChannelBoxAreExtracted() throws {
        let ac3 = try AC3CompressedAudioConfiguration(inspection: .init(frameSize: 1_536,
            sampleRate: 48_000, sampleCount: 1_536, channelCount: 6,
            fscod: 0, bsid: 8, bsmod: 0, acmod: 7, lfeon: true, frmsizecod: 20))
        let eac3 = try EAC3CompressedAudioConfiguration(sampleRate: 48_000, bsid: 16,
            bsmod: 0, audioCodingMode: 7, hasLFE: true, asvc: false, maximumDataRateKbps: 6_144)
        for config: CompressedAudioFormatConfiguration in [.ac3(ac3), .eac3(eac3)] {
            let entry = config.codec == .ac3 ? "ac-3" : "ec-3"
            let channel = Self.channel(bitmap: 0x60F)
            let data = Self.initialization(entry: entry, children: config.serializedBox + channel)
            let facts = try FMP4CompressedAudioInspection.initialization(data)
            XCTAssertEqual(facts.decoderConfiguration, config.serializedBox)
            XCTAssertEqual(facts.channelLayout, .bitmap(0x60F))
            XCTAssertEqual(facts.sampleEntryChannelCount, 2,
                "Dolby channel count derives from dac3/dec3, not this conventional field")
            XCTAssertThrowsError(try FMP4CompressedAudioInspection.initialization(
                Self.initialization(entry: entry, children: config.serializedBox + channel + channel)))
            let absent = try FMP4CompressedAudioInspection.initialization(
                Self.initialization(entry: entry, children: config.serializedBox))
            XCTAssertNil(absent.channelLayout, "Missing layout is not inferred by parser")
        }
    }
    func testDolbyValidationUsesEmittedLayoutAndConfigurationForBothCodecs() throws {
        let ac3 = try AC3CompressedAudioConfiguration(inspection: .init(frameSize: 1_536,
            sampleRate: 48_000, sampleCount: 1_536, channelCount: 6,
            fscod: 0, bsid: 8, bsmod: 0, acmod: 7, lfeon: true, frmsizecod: 20))
        let eac3 = try EAC3CompressedAudioConfiguration(sampleRate: 48_000, bsid: 16,
            bsmod: 0, audioCodingMode: 7, hasLFE: true, asvc: false, maximumDataRateKbps: 6_144)
        for config: CompressedAudioFormatConfiguration in [.ac3(ac3), .eac3(eac3)] {
            let entry = config.codec == .ac3 ? "ac-3" : "ec-3"
            for mask: UInt64 in [0x3F, 0x60F] {
                let source = AudioChannelLayout(channelCount: 6, nativeMask: mask)
                let bytes = Self.initialization(entry: entry, children: config.serializedBox + Self.channel(bitmap: UInt32(mask)))
                let evidence = try DolbyWriterInitializationEvidence.validate(bytes, configuration: config, sourceLayout: source)
                XCTAssertEqual(evidence.channelPositions, UInt32(mask))
                XCTAssertThrowsError(try DolbyWriterInitializationEvidence.validate(
                    Self.initialization(entry: entry, children: config.serializedBox),
                    configuration: config, sourceLayout: source)) { error in
                    XCTAssertEqual(error as? CompressedAudioInitializationRejection, .invalidConfiguration)
                }
                XCTAssertThrowsError(try DolbyWriterInitializationEvidence.validate(bytes,
                    configuration: config, sourceLayout: .init(channelCount: 6, nativeMask: mask == 0x3F ? 0x60F : 0x3F)))
            }
        }
    }

    func testWrongAACDescriptorDoesNotBecomeSourceConfigurationEvidence() throws {
        let cookie = try AudioSpecificConfig.parse(Data([0x11, 0x90])).coreAudioMagicCookie
        var wrongObjectType = cookie
        wrongObjectType[7] = 0x6B
        XCTAssertThrowsError(try FMP4CompressedAudioInspection.initialization(Self.initialization(
            entry: "mp4a", children: Self.box("esds", Data(repeating: 0, count: 4) + wrongObjectType))))
    }
    static func initialization(entry: String, children: Data, timescale: Int32 = 48_000) -> Data {
        var header = Data(repeating: 0, count: 16)
        header.append(contentsOf: [0, 2, 0, 16, 0, 0, 0, 0])
        header.append(u32(48_000 << 16))
        let stsd = box("stsd", Data(repeating: 0, count: 4) + u32(1) + box(entry, header + children))
        let mdhd = box("mdhd", Data(repeating: 0, count: 12) + u32(UInt32(timescale)) + Data(repeating: 0, count: 8))
        let hdlr = box("hdlr", Data(repeating: 0, count: 8) + Data("soun".utf8) + Data(repeating: 0, count: 12))
        return box("moov", box("trak", box("mdia", mdhd + hdlr + box("minf", box("stbl", stsd)))))
    }
    static func channel(bitmap: UInt32) -> Data {
        box("chan", u32(0) + u32(0x00010000) + u32(bitmap) + u32(0))
    }
    static func box(_ name: String, _ payload: Data) -> Data {
        u32(UInt32(payload.count + 8)) + Data(name.utf8) + payload
    }
    static func u32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
}
