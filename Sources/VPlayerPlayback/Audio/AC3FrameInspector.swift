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

struct AC3HeaderInputDomainEntry: Sendable, Hashable {
    let fscod: UInt8
    let bsid: UInt8
    let frmsizecod: UInt8
    let sampleRate: Int32
}

enum AC3FrameInspector {
    static var supportedInputDomain: [AC3HeaderInputDomainEntry] {
        (0..<Int(VPFF_AC3_SUPPORTED_FSCOD_COUNT)).flatMap { fscod in
            (Int(VPFF_AC3_SUPPORTED_BSID_MIN)...Int(VPFF_AC3_SUPPORTED_BSID_MAX)).flatMap { bsid in
                (0..<Int(VPFF_AC3_SUPPORTED_FRMSIZECOD_COUNT)).map { frmsizecod in
                    let sampleRate = vp_ffmpeg_ac3_supported_sample_rate_v1(
                        UInt8(fscod),
                        UInt8(bsid)
                    )
                    precondition(sampleRate > 0)
                    return AC3HeaderInputDomainEntry(
                        fscod: UInt8(fscod),
                        bsid: UInt8(bsid),
                        frmsizecod: UInt8(frmsizecod),
                        sampleRate: sampleRate
                    )
                }
            }
        }
    }

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

enum EAC3StreamType: UInt8, Sendable, Equatable {
    case independent = 0
    case dependent = 1
    case convertedFromAC3 = 2
}

struct EAC3HeaderInputDomainEntry: Sendable, Hashable {
    let sampleRate: Int32
    let blockCount: Int
    let sampleCount: Int32
}

struct EAC3FrameInspection: Sendable, Equatable {
    let frameSize: Int
    let sampleRate: Int32
    let sampleCount: Int32
    let channelCount: Int32
    let streamType: EAC3StreamType
    let substreamID: UInt8
    let bsid: UInt8
    let bsmod: UInt8?
    let acmod: UInt8
    let lfeon: Bool
    let convsync: Bool?
    let hasJOC: Bool?

    var blockCount: Int { Int(sampleCount / 256) }
}

/// 只借用一个完整 E-AC-3 syncframe，并保留服务分类所需的 header 事实。
enum EAC3FrameInspector {
    static let primarySampleRates: [Int32] = [48_000, 44_100, 32_000]
    static let reducedSampleRates: [Int32] = [24_000, 22_050, 16_000]
    static let primaryBlockCounts = [1, 2, 3, 6]

    static var supportedInputDomain: [EAC3HeaderInputDomainEntry] {
        primarySampleRates.flatMap { sampleRate in
            primaryBlockCounts.map { blockCount in
                EAC3HeaderInputDomainEntry(
                    sampleRate: sampleRate,
                    blockCount: blockCount,
                    sampleCount: Int32(blockCount * 256)
                )
            }
        } + reducedSampleRates.map { sampleRate in
            EAC3HeaderInputDomainEntry(
                sampleRate: sampleRate,
                blockCount: 6,
                sampleCount: 1_536
            )
        }
    }

    static func inspect(_ frame: Data) throws -> EAC3FrameInspection {
        guard frame.count >= 8, frame.count <= 4_096, frame.count.isMultiple(of: 2) else {
            throw AudioCodecProfileValidation.error()
        }
        var reader = EAC3BitReader(frame)
        guard try reader.read(16) == 0x0B77,
              let streamType = EAC3StreamType(rawValue: UInt8(try reader.read(2))) else {
            throw AudioCodecProfileValidation.error()
        }
        let substreamID = UInt8(try reader.read(3))
        let frameSize = 2 * (try reader.read(11) + 1)
        guard frameSize == frame.count else { throw AudioCodecProfileValidation.error() }

        let fscod = try reader.read(2)
        let sampleRate: Int32
        let blockCount: Int
        if fscod == 3 {
            let fscod2 = try reader.read(2)
            guard fscod2 < reducedSampleRates.count else { throw AudioCodecProfileValidation.error() }
            sampleRate = reducedSampleRates[fscod2]
            blockCount = 6
        } else {
            sampleRate = primarySampleRates[fscod]
            blockCount = primaryBlockCounts[try reader.read(2)]
        }
        let acmod = UInt8(try reader.read(3))
        let lfeon = try reader.read(1) != 0
        let bsid = UInt8(try reader.read(5))
        guard (11...16).contains(bsid) else { throw AudioCodecProfileValidation.error() }

        _ = try reader.read(5) // dialnorm
        if try reader.read(1) != 0 { _ = try reader.read(8) }
        if acmod == 0 {
            _ = try reader.read(5)
            if try reader.read(1) != 0 { _ = try reader.read(8) }
        }
        if streamType == .dependent, try reader.read(1) != 0 {
            _ = try reader.read(16)
        }

        // 完整mix metadata的语法依赖acmod与block数；存在时服务字段不能被猜测。
        let hasMixMetadata = try reader.read(1) != 0
        let bsmod: UInt8?
        var convsync: Bool?
        let hasJOC: Bool?
        if hasMixMetadata {
            bsmod = nil
            convsync = nil
            hasJOC = nil
        } else {
            let hasInfoMetadata = try reader.read(1) != 0
            if hasInfoMetadata {
                bsmod = UInt8(try reader.read(3))
                _ = try reader.read(1) // copyrightb
                _ = try reader.read(1) // origbs
                if acmod == 2 {
                    _ = try reader.read(2) // dsurmod
                    _ = try reader.read(2) // dheadphonmod
                }
                if acmod >= 6 { _ = try reader.read(2) }
                if acmod == 0 { _ = try reader.read(2) }
                if try reader.read(1) != 0 { _ = try reader.read(8) }
                if acmod == 0, try reader.read(1) != 0 { _ = try reader.read(8) }
                if fscod < 3 { _ = try reader.read(1) }
            } else {
                bsmod = nil
            }
            if streamType == .independent, blockCount < 6 {
                convsync = try reader.read(1) != 0
            } else {
                convsync = nil
            }
            if streamType == .convertedFromAC3 {
                if blockCount == 6 {
                    _ = try reader.read(6) // 转换前AC-3帧的frmsizecod
                } else if try reader.read(1) != 0 {
                    _ = try reader.read(6)
                }
            }

            // 与FFmpeg公开parser一致：addbsil给出附加字段字节数，首字节最低位是extension type A。
            if try reader.read(1) == 0 {
                hasJOC = false
            } else {
                let additionalByteCount = try reader.read(6) + 1
                let firstExtensionByte = try reader.read(8)
                let extensionTypeA = firstExtensionByte & 1 != 0
                guard !extensionTypeA || additionalByteCount >= 2 else {
                    throw AudioCodecProfileValidation.error()
                }
                for _ in 1..<additionalByteCount { _ = try reader.read(8) }
                hasJOC = extensionTypeA
            }
        }

        let baseChannels: [Int32] = [2, 1, 2, 3, 3, 4, 4, 5]
        return EAC3FrameInspection(
            frameSize: frameSize,
            sampleRate: sampleRate,
            sampleCount: Int32(blockCount * 256),
            channelCount: baseChannels[Int(acmod)] + (lfeon ? 1 : 0),
            streamType: streamType,
            substreamID: substreamID,
            bsid: bsid,
            bsmod: bsmod,
            acmod: acmod,
            lfeon: lfeon,
            convsync: convsync,
            hasJOC: hasJOC
        )
    }
}

private struct EAC3BitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func read(_ count: Int) throws -> Int {
        guard count >= 0, count <= 24,
              bitOffset <= bytes.count * 8,
              count <= bytes.count * 8 - bitOffset else {
            throw AudioCodecProfileValidation.error()
        }
        var result = 0
        for _ in 0..<count {
            let byte = bytes[bitOffset / 8]
            result = result << 1 | Int((byte >> UInt8(7 - bitOffset % 8)) & 1)
            bitOffset += 1
        }
        return result
    }
}
