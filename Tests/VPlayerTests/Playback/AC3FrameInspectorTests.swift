// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class AC3FrameInspectorTests: XCTestCase {
    func testInspectorABIV1OffsetsSizeAndReservedBytesAreStable() throws {
        XCTAssertEqual(VPFF_AC3_INSPECTOR_ABI_VERSION, 1)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.size, 32)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.abi_version), 0)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.struct_size), 4)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.frame_size), 8)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.sample_rate), 12)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.sample_count), 16)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.channel_count), 20)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.fscod), 24)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.bsid), 25)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.bsmod), 26)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.acmod), 27)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.lfeon), 28)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.frmsizecod), 29)
        XCTAssertEqual(MemoryLayout<VPFFAC3FrameInfoV1>.offset(of: \.reserved), 30)

        let info = try inspect(AssemblerTestFixtures.syntheticAC3Frame())
        XCTAssertEqual(info.abi_version, 1)
        XCTAssertEqual(info.struct_size, 32)
        XCTAssertEqual(withUnsafeBytes(of: info.reserved) { Array($0) }, [0, 0])
    }

    func testInspectorAcceptsCompleteValidCRCFrameIncludingBsidTen() throws {
        let classic = try inspect(AssemblerTestFixtures.syntheticAC3Frame(
            fscod: 0, frmsizecod: 20, bsid: 8, bsmod: 3, acmod: 7, lfeon: true
        ))
        XCTAssertEqual(classic.frame_size, 768)
        XCTAssertEqual(classic.sample_rate, 48_000)
        XCTAssertEqual(classic.sample_count, 1_536)
        XCTAssertEqual(classic.channel_count, 6)
        XCTAssertEqual(classic.fscod, 0)
        XCTAssertEqual(classic.bsid, 8)
        XCTAssertEqual(classic.bsmod, 3)
        XCTAssertEqual(classic.acmod, 7)
        XCTAssertEqual(classic.lfeon, 1)
        XCTAssertEqual(classic.frmsizecod, 20)

        let bsidTen = try inspect(AssemblerTestFixtures.syntheticAC3Frame(
            fscod: 0, frmsizecod: 20, bsid: 10, bsmod: 0, acmod: 2, lfeon: false
        ))
        XCTAssertEqual(bsidTen.bsid, 10)
        XCTAssertEqual(bsidTen.sample_rate, 12_000)
        XCTAssertEqual(bsidTen.channel_count, 2)
    }

    func testInspectorRejectsBadSyncSizeBsidAboveTenAndCRC() {
        let valid = AssemblerTestFixtures.syntheticAC3Frame()
        var badSync = valid
        badSync[0] = 0
        var badBsid = valid
        badBsid[5] = (badBsid[5] & 0x07) | (11 << 3)
        var badCRC = valid
        badCRC[badCRC.count - 1] ^= 1

        XCTAssertNotEqual(inspectStatus(badSync), 0)
        XCTAssertNotEqual(inspectStatus(Data(valid.dropLast())), 0)
        XCTAssertNotEqual(inspectStatus(valid + Data([0])), 0)
        XCTAssertNotEqual(inspectStatus(badBsid), 0)
        XCTAssertNotEqual(inspectStatus(badCRC), 0)
    }

    func testInspectorReadsConditionalLFEPositionForEveryACMod() throws {
        let expectedBaseChannels: [Int32] = [2, 1, 2, 3, 3, 4, 4, 5]
        for acmod in UInt8(0)...UInt8(7) {
            let withoutLFE = try inspect(AssemblerTestFixtures.syntheticAC3Frame(
                acmod: acmod, lfeon: false
            ))
            let withLFE = try inspect(AssemblerTestFixtures.syntheticAC3Frame(
                acmod: acmod, lfeon: true
            ))
            XCTAssertEqual(withoutLFE.acmod, acmod)
            XCTAssertEqual(withoutLFE.lfeon, 0, "acmod=\(acmod)")
            XCTAssertEqual(withoutLFE.channel_count, expectedBaseChannels[Int(acmod)])
            XCTAssertEqual(withLFE.acmod, acmod)
            XCTAssertEqual(withLFE.lfeon, 1, "acmod=\(acmod)")
            XCTAssertEqual(withLFE.channel_count, expectedBaseChannels[Int(acmod)] + 1)
        }
    }

    private func inspect(_ data: Data) throws -> VPFFAC3FrameInfoV1 {
        var info = VPFFAC3FrameInfoV1()
        let status = data.withUnsafeBytes { bytes in
            vp_ffmpeg_inspect_ac3_frame_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &info
            )
        }
        XCTAssertEqual(status, 0)
        return info
    }

    private func inspectStatus(_ data: Data) -> Int32 {
        var info = VPFFAC3FrameInfoV1()
        return data.withUnsafeBytes { bytes in
            vp_ffmpeg_inspect_ac3_frame_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &info
            )
        }
    }
}
