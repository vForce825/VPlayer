// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct AC3FrameInspection: Sendable, Equatable {
    let frameSize: Int
    let sampleRate: Int32
    let sampleCount: Int32
    let channelCount: Int32
    let fscod: UInt8
    let bsid: UInt8
    let bsmod: UInt8
    let acmod: UInt8
    let lfeon: Bool
    let frmsizecod: UInt8
}

enum AC3FrameInspector {
    static func inspect(_ frame: Data) throws -> AC3FrameInspection {
        var info = VPFFAC3FrameInfoV1()
        let result = frame.withUnsafeBytes { bytes in
            vp_ffmpeg_inspect_ac3_frame_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &info
            )
        }
        let expectedFrameSize = UInt32(exactly: frame.count)
        guard result == 0,
              info.abi_version == VPFF_AC3_INSPECTOR_ABI_VERSION,
              info.struct_size == UInt32(MemoryLayout<VPFFAC3FrameInfoV1>.size),
              info.frame_size == expectedFrameSize else {
            throw AudioCodecProfileValidation.error()
        }
        return AC3FrameInspection(
            frameSize: Int(info.frame_size),
            sampleRate: info.sample_rate,
            sampleCount: info.sample_count,
            channelCount: info.channel_count,
            fscod: info.fscod,
            bsid: info.bsid,
            bsmod: info.bsmod,
            acmod: info.acmod,
            lfeon: info.lfeon != 0,
            frmsizecod: info.frmsizecod
        )
    }
}
