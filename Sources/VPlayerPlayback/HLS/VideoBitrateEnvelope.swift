// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum VideoCodecProfileLevel: Sendable, Hashable {
    case h264(profileIDC: UInt8, compatibilityFlags: UInt32, levelIDC: UInt8)
    case hevc(profileIDC: UInt8, tier: VideoCodecTier, levelIDC: UInt8)
}

enum VideoBitrateEnvelopeError: Error, Sendable, Equatable {
    case unsupportedProfileLevel
    case missingLevelEvidence
    case levelFrameSizeExceeded
    case levelSampleRateExceeded
    case levelDecodedPictureBufferExceeded
    case invalidDuration
    case arithmeticOverflow
}

/// 一个 remux format generation 的冻结码率包络。
///
/// 所有数值都是十进制 bit/s。普通 measured bitrate 不参与冻结；后续 segment
/// 是否超限由 publisher 层使用相同精确算术检查，本类型只提供无浮点的基础判定。
struct VideoBitrateEnvelope: Sendable, Hashable {
    static let maximumPayloadBitsPerSecond: UInt64 = 80_000_000
    static let minimumOverheadBitsPerSecond: UInt64 = 256_000

    let profileLevel: VideoCodecProfileLevel
    let payloadBitsPerSecond: UInt64
    let overheadBitsPerSecond: UInt64
    let declaredBitsPerSecond: UInt64

    static func freeze(
        profileLevel: VideoCodecProfileLevel
    ) throws -> VideoBitrateEnvelope {
        let standardMaximum = try standardMaximumBitsPerSecond(for: profileLevel)
        let payload = min(maximumPayloadBitsPerSecond, standardMaximum)
        let (scaledOverhead, scaleOverflow) = payload.multipliedReportingOverflow(by: 2)
        guard !scaleOverflow else { throw VideoBitrateEnvelopeError.arithmeticOverflow }
        let (roundedNumerator, roundOverflow) = scaledOverhead.addingReportingOverflow(99)
        guard !roundOverflow else { throw VideoBitrateEnvelopeError.arithmeticOverflow }
        let overhead = max(minimumOverheadBitsPerSecond, roundedNumerator / 100)
        let (declared, declaredOverflow) = payload.addingReportingOverflow(overhead)
        guard !declaredOverflow else { throw VideoBitrateEnvelopeError.arithmeticOverflow }
        return VideoBitrateEnvelope(
            profileLevel: profileLevel,
            payloadBitsPerSecond: payload,
            overheadBitsPerSecond: overhead,
            declaredBitsPerSecond: declared
        )
    }

    /// 按 ITU-T H.264 表 A-1／H.265 表 A.6 的联合约束校验实际图像。
    ///
    /// H.264 使用裁剪前 `PicSizeInMbs`，HEVC 使用裁剪前 `PicSizeInSamplesY`；
    /// 不能从展示尺寸反推这两个值，否则裁剪会低估 level 消耗。
    static func validateLevel(
        profileLevel: VideoCodecProfileLevel,
        frameRate: MediaRational?,
        codedPictureSizeInMacroblocks: UInt32?,
        codedLumaPictureSize: UInt64?,
        maximumReferenceFrames: UInt32?
    ) throws {
        guard let frameRate, let maximumReferenceFrames else {
            throw VideoBitrateEnvelopeError.missingLevelEvidence
        }
        _ = try standardMaximumBitsPerSecond(for: profileLevel)

        switch profileLevel {
        case let .h264(profileIDC, compatibilityFlags, levelIDC):
            guard let pictureSize = codedPictureSizeInMacroblocks,
                  pictureSize > 0 else {
                throw VideoBitrateEnvelopeError.missingLevelEvidence
            }
            let limits = try h264LevelLimits(
                profileIDC: profileIDC,
                compatibilityFlags: compatibilityFlags,
                levelIDC: levelIDC
            )
            let pictureSize64 = UInt64(pictureSize)
            guard pictureSize64 <= limits.maximumFrameMacroblocks else {
                throw VideoBitrateEnvelopeError.levelFrameSizeExceeded
            }
            try validateSampleRate(
                pictureSize: pictureSize64,
                frameRate: frameRate,
                maximumSamplesPerSecond: limits.maximumMacroblocksPerSecond
            )
            let maximumReferences = min(
                limits.maximumDecodedPictureBufferMacroblocks / pictureSize64,
                16
            )
            guard UInt64(maximumReferenceFrames) <= maximumReferences else {
                throw VideoBitrateEnvelopeError.levelDecodedPictureBufferExceeded
            }

        case let .hevc(_, _, levelIDC):
            guard let pictureSize = codedLumaPictureSize,
                  pictureSize > 0 else {
                throw VideoBitrateEnvelopeError.missingLevelEvidence
            }
            let limits = try hevcLevelLimits(levelIDC)
            guard pictureSize <= limits.maximumLumaPictureSize else {
                throw VideoBitrateEnvelopeError.levelFrameSizeExceeded
            }
            try validateSampleRate(
                pictureSize: pictureSize,
                frameRate: frameRate,
                maximumSamplesPerSecond: limits.maximumLumaSampleRate
            )
            let maximumReferences = try hevcMaximumDecodedPictures(
                pictureSize: pictureSize,
                maximumLumaPictureSize: limits.maximumLumaPictureSize
            )
            guard UInt64(maximumReferenceFrames) <= maximumReferences else {
                throw VideoBitrateEnvelopeError.levelDecodedPictureBufferExceeded
            }
        }
    }

    /// 按 `8 * media-file bytes / duration` 检查单个候选区间。
    func admitsMediaFile(
        byteCount: UInt64,
        duration: ExactMediaTime
    ) throws -> Bool {
        guard duration.value > 0 else { throw VideoBitrateEnvelopeError.invalidDuration }
        let (bits, bitsOverflow) = byteCount.multipliedReportingOverflow(by: 8)
        guard !bitsOverflow else { throw VideoBitrateEnvelopeError.arithmeticOverflow }
        let (left, leftOverflow) = bits.multipliedReportingOverflow(
            by: UInt64(duration.timescale)
        )
        let (right, rightOverflow) = declaredBitsPerSecond.multipliedReportingOverflow(
            by: UInt64(duration.value)
        )
        guard !leftOverflow, !rightOverflow else {
            throw VideoBitrateEnvelopeError.arithmeticOverflow
        }
        return left <= right
    }

    private static func standardMaximumBitsPerSecond(
        for profileLevel: VideoCodecProfileLevel
    ) throws -> UInt64 {
        switch profileLevel {
        case let .h264(profileIDC, compatibilityFlags, levelIDC):
            let base: UInt64
            if isH264Level1B(
                profileIDC: profileIDC,
                compatibilityFlags: compatibilityFlags,
                levelIDC: levelIDC
            ) {
                base = 128_000
            } else {
                switch levelIDC {
                case 10: base = 64_000
                case 11: base = 192_000
                case 12: base = 384_000
                case 13: base = 768_000
                case 20: base = 2_000_000
                case 21, 22: base = 4_000_000
                case 30: base = 10_000_000
                case 31: base = 14_000_000
                case 32, 40: base = 20_000_000
                case 41, 42: base = 50_000_000
                case 50: base = 135_000_000
                case 51, 52: base = 240_000_000
                default: throw VideoBitrateEnvelopeError.unsupportedProfileLevel
                }
            }
            switch profileIDC {
            case 66, 77:
                return base
            case 100:
                let (scaled, overflow) = base.multipliedReportingOverflow(by: 5)
                guard !overflow else { throw VideoBitrateEnvelopeError.arithmeticOverflow }
                return scaled / 4
            default:
                throw VideoBitrateEnvelopeError.unsupportedProfileLevel
            }

        case let .hevc(profileIDC, tier, levelIDC):
            guard profileIDC == 1 || profileIDC == 2 else {
                throw VideoBitrateEnvelopeError.unsupportedProfileLevel
            }
            switch (tier, levelIDC) {
            case (.main, 30): return 128_000
            case (.main, 60): return 1_500_000
            case (.main, 63): return 3_000_000
            case (.main, 90): return 6_000_000
            case (.main, 93): return 10_000_000
            case (.main, 120): return 12_000_000
            case (.high, 120): return 30_000_000
            case (.main, 123): return 20_000_000
            case (.high, 123): return 50_000_000
            case (.main, 150): return 25_000_000
            case (.high, 150): return 100_000_000
            case (.main, 153): return 40_000_000
            case (.high, 153): return 160_000_000
            case (.main, 156), (.main, 180): return 60_000_000
            case (.high, 156), (.high, 180): return 240_000_000
            case (.main, 183): return 120_000_000
            case (.high, 183): return 480_000_000
            case (.main, 186): return 240_000_000
            case (.high, 186): return 800_000_000
            default: throw VideoBitrateEnvelopeError.unsupportedProfileLevel
            }
        }
    }

    private struct H264LevelLimits {
        let maximumMacroblocksPerSecond: UInt64
        let maximumFrameMacroblocks: UInt64
        let maximumDecodedPictureBufferMacroblocks: UInt64

        init(_ maximumMacroblocksPerSecond: UInt64,
             _ maximumFrameMacroblocks: UInt64,
             _ maximumDecodedPictureBufferMacroblocks: UInt64) {
            self.maximumMacroblocksPerSecond = maximumMacroblocksPerSecond
            self.maximumFrameMacroblocks = maximumFrameMacroblocks
            self.maximumDecodedPictureBufferMacroblocks = maximumDecodedPictureBufferMacroblocks
        }
    }

    private static func h264LevelLimits(
        profileIDC: UInt8,
        compatibilityFlags: UInt32,
        levelIDC: UInt8
    ) throws -> H264LevelLimits {
        if isH264Level1B(
            profileIDC: profileIDC,
            compatibilityFlags: compatibilityFlags,
            levelIDC: levelIDC
        ) {
            return H264LevelLimits(1_485, 99, 396)
        }
        switch levelIDC {
        case 10: return H264LevelLimits(1_485, 99, 396)
        case 11: return H264LevelLimits(3_000, 396, 900)
        case 12: return H264LevelLimits(6_000, 396, 2_376)
        case 13: return H264LevelLimits(11_880, 396, 2_376)
        case 20: return H264LevelLimits(11_880, 396, 2_376)
        case 21: return H264LevelLimits(19_800, 792, 4_752)
        case 22: return H264LevelLimits(20_250, 1_620, 8_100)
        case 30: return H264LevelLimits(40_500, 1_620, 8_100)
        case 31: return H264LevelLimits(108_000, 3_600, 18_000)
        case 32: return H264LevelLimits(216_000, 5_120, 20_480)
        case 40, 41: return H264LevelLimits(245_760, 8_192, 32_768)
        case 42: return H264LevelLimits(522_240, 8_704, 34_816)
        case 50: return H264LevelLimits(589_824, 22_080, 110_400)
        case 51: return H264LevelLimits(983_040, 36_864, 184_320)
        case 52: return H264LevelLimits(2_073_600, 36_864, 184_320)
        default: throw VideoBitrateEnvelopeError.unsupportedProfileLevel
        }
    }

    /// H.264 A.3.1：Baseline/Main 的 level_idc=11 只有在 constraint_set3_flag
    /// 置位时才表示 Level 1b；其余组合仍按 Level 1.1 处理。
    private static func isH264Level1B(
        profileIDC: UInt8,
        compatibilityFlags: UInt32,
        levelIDC: UInt8
    ) -> Bool {
        levelIDC == 11
            && (profileIDC == 66 || profileIDC == 77)
            && compatibilityFlags & 0x10 != 0
    }

    private struct HEVCLevelLimits {
        let maximumLumaPictureSize: UInt64
        let maximumLumaSampleRate: UInt64

        init(_ maximumLumaPictureSize: UInt64, _ maximumLumaSampleRate: UInt64) {
            self.maximumLumaPictureSize = maximumLumaPictureSize
            self.maximumLumaSampleRate = maximumLumaSampleRate
        }
    }

    private static func hevcLevelLimits(_ levelIDC: UInt8) throws -> HEVCLevelLimits {
        switch levelIDC {
        case 30: return HEVCLevelLimits(36_864, 552_960)
        case 60: return HEVCLevelLimits(122_880, 3_686_400)
        case 63: return HEVCLevelLimits(245_760, 7_372_800)
        case 90: return HEVCLevelLimits(552_960, 16_588_800)
        case 93: return HEVCLevelLimits(983_040, 33_177_600)
        case 120: return HEVCLevelLimits(2_228_224, 66_846_720)
        case 123: return HEVCLevelLimits(2_228_224, 133_693_440)
        case 150: return HEVCLevelLimits(8_912_896, 267_386_880)
        case 153: return HEVCLevelLimits(8_912_896, 534_773_760)
        case 156: return HEVCLevelLimits(8_912_896, 1_069_547_520)
        case 180: return HEVCLevelLimits(35_651_584, 1_069_547_520)
        case 183: return HEVCLevelLimits(35_651_584, 2_139_095_040)
        case 186: return HEVCLevelLimits(35_651_584, 4_278_190_080)
        default: throw VideoBitrateEnvelopeError.unsupportedProfileLevel
        }
    }

    private static func validateSampleRate(
        pictureSize: UInt64,
        frameRate: MediaRational,
        maximumSamplesPerSecond: UInt64
    ) throws {
        let (actual, actualOverflow) = pictureSize.multipliedReportingOverflow(
            by: UInt64(frameRate.num)
        )
        let (maximum, maximumOverflow) = maximumSamplesPerSecond
            .multipliedReportingOverflow(by: UInt64(frameRate.den))
        guard !actualOverflow, !maximumOverflow else {
            throw VideoBitrateEnvelopeError.arithmeticOverflow
        }
        guard actual <= maximum else {
            throw VideoBitrateEnvelopeError.levelSampleRateExceeded
        }
    }

    /// H.265 A.4.2 的 MaxDpbSize 分段规则，基础 MaxDpbPicBuf 为六张。
    private static func hevcMaximumDecodedPictures(
        pictureSize: UInt64,
        maximumLumaPictureSize: UInt64
    ) throws -> UInt64 {
        let (fourPictures, fourOverflow) = pictureSize.multipliedReportingOverflow(by: 4)
        let (twoPictures, twoOverflow) = pictureSize.multipliedReportingOverflow(by: 2)
        let (threeMaximum, maximumOverflow) = maximumLumaPictureSize
            .multipliedReportingOverflow(by: 3)
        guard !fourOverflow, !twoOverflow, !maximumOverflow else {
            throw VideoBitrateEnvelopeError.arithmeticOverflow
        }
        if fourPictures <= maximumLumaPictureSize { return 16 }
        if twoPictures <= maximumLumaPictureSize { return 12 }
        if fourPictures <= threeMaximum { return 8 }
        return 6
    }
}
