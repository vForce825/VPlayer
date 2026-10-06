// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class NativeHLSSelectedVideoFormatTests: XCTestCase {
    func testSameParameterSetsCannotBorrowPreflightColorAfterContainerTransferChanges() throws {
        let fixture = try NativeColorFixture()
        let admitted = try fixture.facts(sampleEntry: "avc1")
        XCTAssertNoThrow(try SystemNativeHLSAssetInspector.videoFacts(fixture.format(), expected: admitted))
        for transfer in [kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG] {
            let changed = try fixture.format(transfer: transfer)
            XCTAssertEqual(try parameterSets(changed), fixture.parameters,
                "The regression must keep SPS/PPS and dimensions identical")
            XCTAssertThrowsError(try SystemNativeHLSAssetInspector.videoFacts(changed, expected: admitted))
        }
    }
    func testKnownPreflightColorDoesNotFillMissingUnknownOrContradictoryCurrentFields() throws {
        let fixture = try NativeColorFixture(), admitted = try fixture.facts(sampleEntry: "avc1")
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix] {
            XCTAssertThrowsError(try SystemNativeHLSAssetInspector.videoFacts(fixture.format(omit: key), expected: admitted))
        }
        XCTAssertThrowsError(try SystemNativeHLSAssetInspector.videoFacts(fixture.format(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020), expected: admitted))
        XCTAssertThrowsError(try SystemNativeHLSAssetInspector.videoFacts(fixture.format(matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020), expected: admitted))
        XCTAssertThrowsError(try SystemNativeHLSAssetInspector.videoFacts(fixture.format(transfer: "Unspecified" as CFString), expected: admitted))
        XCTAssertThrowsError(try SystemNativeHLSAssetInspector.videoFacts(fixture.format(alternativeTransfer: true), expected: admitted))
    }
    func testNativeSampleEntryDoesNotSilentlyCollapseContainerAliases() throws {
        let fixture = try NativeColorFixture(), format = try fixture.format()
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_H264)
        XCTAssertNoThrow(try SystemNativeHLSAssetInspector.videoFacts(format, expected: fixture.facts(sampleEntry: "avc1")))
        XCTAssertThrowsError(try SystemNativeHLSAssetInspector.videoFacts(format, expected: fixture.facts(sampleEntry: "avc3")))
        XCTAssertNoThrow(try SystemNativeHLSAssetInspector.videoFacts(format, expected: fixture.facts(sampleEntry: nil, container: .mpegTS)))
        XCTAssertThrowsError(try SystemNativeHLSAssetInspector.videoFacts(format, expected: fixture.facts(sampleEntry: nil, container: .fragmentedMP4)))
    }
    func testSelectedSPSPeriodRequiresExplicitProgressiveFixedTiming() throws {
        let fixed = try NativeColorFixture(fixedTiming: true)
        XCTAssertEqual(SystemNativeHLSAssetInspector.selectedFixedFrameRate(parameterSets: fixed.parameters, codec: .h264),
            MediaRational(num: 25, den: 1))
        for unsupported in [try NativeColorFixture(), try NativeColorFixture(fixedTiming: false)] {
            XCTAssertNil(SystemNativeHLSAssetInspector.selectedFixedFrameRate(parameterSets: unsupported.parameters, codec: .h264))
        }
        XCTAssertNil(SystemNativeHLSAssetInspector.selectedFixedFrameRate(parameterSets: fixed.parameters, codec: .hevc),
            "HEVC POC timing alone is not an explicit fixed presentation cadence")
        let different = try NativeColorFixture(fixedTiming: true, timeScale: 60)
        XCTAssertNil(SystemNativeHLSAssetInspector.selectedFixedFrameRate(
            parameterSets: fixed.parameters + [different.parameters[0]], codec: .h264))
    }

    private func parameterSets(_ format: CMFormatDescription) throws -> [Data] {
        var count = 0, width: Int32 = 0
        var values: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, length = 0
            XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &length, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &width), noErr)
            values.append(Data(bytes: try XCTUnwrap(pointer), count: length))
        }
        XCTAssertEqual(count, 2)
        return values
    }
}

/// Ordinary High-profile 1080p parameter sets omit VUI color, so the only
/// effective color comes from the container's Core Media extension dictionary.
private struct NativeColorFixture {
    let parameters: [Data]
    let base: CMFormatDescription
    init(fixedTiming: Bool? = nil, timeScale: UInt64 = 50) throws {
        var sps = NativeColorBits()
        sps.write(100, count: 8); sps.write(0, count: 8); sps.write(40, count: 8)
        sps.ue(0); sps.ue(1); sps.ue(0); sps.ue(0)
        sps.write(0, count: 1); sps.write(0, count: 1)
        sps.ue(0); sps.ue(0); sps.ue(0); sps.ue(4); sps.write(0, count: 1)
        sps.ue(119); sps.ue(67); sps.write(1, count: 1); sps.write(1, count: 1)
        sps.write(1, count: 1); sps.ue(0); sps.ue(0); sps.ue(0); sps.ue(4)
        if let fixedTiming {
            sps.write(1, count: 1) // VUI, with no appearance overrides
            sps.write(0, count: 1); sps.write(0, count: 1); sps.write(0, count: 1); sps.write(0, count: 1)
            sps.write(1, count: 1); sps.write(1, count: 32); sps.write(timeScale, count: 32)
            sps.write(fixedTiming ? 1 : 0, count: 1)
            sps.write(0, count: 1); sps.write(0, count: 1); sps.write(0, count: 1); sps.write(0, count: 1)
        } else { sps.write(0, count: 1) } // no VUI in appearance regressions
        var pps = NativeColorBits()
        pps.ue(0); pps.ue(0); pps.write(0, count: 1); pps.write(0, count: 1)
        pps.ue(0); pps.ue(0); pps.ue(0); pps.write(0, count: 1); pps.write(0, count: 2)
        pps.ue(0); pps.ue(0); pps.ue(0); pps.write(1, count: 1); pps.write(0, count: 1); pps.write(0, count: 1)
        parameters = [sps.finish(header: 0x67), pps.finish(header: 0x68)]
        base = try VideoFormatDescriptionBuilder.make(codec: .h264, parameterSets: parameters)
    }
    func format(primaries: CFString = kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                transfer: CFString = kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                matrix: CFString = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
                omit: CFString? = nil, alternativeTransfer: Bool = false) throws -> CMFormatDescription {
        var extensions = CMFormatDescriptionGetExtensions(base) as? [String: Any] ?? [:]
        extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries
        extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transfer
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = matrix
        if let omit { extensions.removeValue(forKey: omit as String) }
        if alternativeTransfer { extensions[kCMFormatDescriptionExtension_AlternativeTransferCharacteristics as String] = 18 }
        var result: CMFormatDescription?
        let size = CMVideoFormatDescriptionGetDimensions(base)
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: size.width, height: size.height, extensions: extensions as CFDictionary, formatDescriptionOut: &result)
        guard status == noErr else { throw HLSSourceError.unsupportedMedia }
        return try XCTUnwrap(result)
    }
    func facts(sampleEntry: String?, container: HLSMediaFacts.Container = .fragmentedMP4) throws -> HLSCompatibilityFacts {
        let context = try sourceContext()
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1, topology: .media(Data()))
        let dimensions = CMVideoFormatDescriptionGetDimensions(base)
        let video = HLSVideoFacts(codec: .h264, profile: 100, scan: .progressive, parameterSetsValidated: true,
            configurationFingerprint: try HLSVideoConfigurationFingerprint.make(codec: .h264, parameterSets: parameters),
            width: dimensions.width, height: dimensions.height, chromaFormat: 1, bitDepth: 8, level: 40,
            tier: .main, frameRate: MediaRational(num: 25, den: 1), videoRange: .sdr,
            colorPrimaries: .bt709, colorTransfer: .bt709, colorMatrix: .bt709, sampleEntry: sampleEntry)
        return .init(source: source, media: [.init(url: context.entryURL, container: container, video: video,
            audio: [], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 32)
    }
}
private struct NativeColorBits {
    private var bytes: [UInt8] = [], current: UInt8 = 0, used = 0
    mutating func write(_ value: UInt64, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            current = current << 1 | UInt8((value >> shift) & 1); used += 1
            if used == 8 { bytes.append(current); current = 0; used = 0 }
        }
    }
    mutating func ue(_ value: UInt32) {
        let code = UInt64(value) + 1, count = 64 - (UInt64(value) + 1).leadingZeroBitCount
        if count > 1 { write(0, count: count - 1) }; write(code, count: count)
    }
    mutating func finish(header: UInt8) -> Data {
        write(1, count: 1); if used > 0 { write(0, count: 8 - used) }
        var result = Data([header]), zeros = 0
        for byte in bytes {
            if zeros >= 2, byte <= 3 { result.append(3); zeros = 0 }
            result.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        return result
    }
}
