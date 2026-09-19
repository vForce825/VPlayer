// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation

struct VideoEncodingFrameIdentity: Sendable, Hashable {
    let generation: MediaGeneration
    let accessUnitID: UInt64
    let sequenceNumber: UInt64
    /// 同一真实场画面为补齐源时间轴空洞而重复编码时的有限序号；0 表示真实帧。
    let gapFillOrdinal: UInt32

    init(
        generation: MediaGeneration,
        accessUnitID: UInt64,
        sequenceNumber: UInt64,
        gapFillOrdinal: UInt32 = 0
    ) {
        self.generation = generation
        self.accessUnitID = accessUnitID
        self.sequenceNumber = sequenceNumber
        self.gapFillOrdinal = gapFillOrdinal
    }
}

/// 表面所有权独立于 Swift 对 CVPixelBuffer 的强引用。
///
/// 编码器必须持有它直到 native callback 或终态；显式释放、错误回收和析构可以
/// 竞争，但底层预算／owner 只会收到一次释放。
final class VideoEncodingSurfaceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void) {
        releaseAction = release
    }

    func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { releaseAction = nil }
            return releaseAction
        }
        action?()
    }

    deinit { release() }
}

/// 编码输入的不可变语义签名；逐帧附件不能在 session 建立后偷偷改写格式。
struct VideoEncodingInputFormatSignature: Sendable, Equatable {
    let pixelFormat: OSType
    let width: Int32
    let height: Int32
    let bitDepth: UInt8
    let range: VideoFormatMetadata.Range
    let primaries: VideoFormatMetadata.Primaries
    let transfer: VideoFormatMetadata.Transfer
    let matrix: VideoFormatMetadata.Matrix
    let cleanAperture: HLSCleanApertureSignature?
    let sampleAspectRatio: MediaRational?
    let chromaLocation: VideoFormatMetadata.ChromaLocation
    let masteringDisplayColorVolume: Data?
    let contentLightLevelInfo: Data?

    var dynamicRange: HLSVideoDynamicRange {
        switch transfer {
        case .hlg: .hlg
        case .pq: .pq
        case .bt709, .linear, .unknown: .sdr
        }
    }
}

struct VideoEncodingFrame: @unchecked Sendable {
    let identity: VideoEncodingFrameIdentity
    let pixelBuffer: CVPixelBuffer
    let surfaceLease: VideoEncodingSurfaceLease
    let presentationTimeStamp: CMTime
    let duration: CMTime
    let presentationOrigin: PresentationOrigin
    let reliableFieldOrder: ResolvedFieldOrder?
    let inputFormatSignature: VideoEncodingInputFormatSignature

    init(
        identity: VideoEncodingFrameIdentity,
        pixelBuffer: CVPixelBuffer,
        surfaceLease: VideoEncodingSurfaceLease,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        presentationOrigin: PresentationOrigin,
        reliableFieldOrder: ResolvedFieldOrder?,
        inputFormatSignature: VideoEncodingInputFormatSignature
    ) throws {
        guard presentationTimeStamp.isNumeric,
              presentationTimeStamp.epoch == 0,
              duration.isNumeric,
              duration.epoch == 0,
              CMTimeCompare(duration, .zero) > 0 else {
            surfaceLease.release()
            throw VTVideoEncoderFailure.invalidTime
        }
        self.identity = identity
        self.pixelBuffer = pixelBuffer
        self.surfaceLease = surfaceLease
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.presentationOrigin = presentationOrigin
        self.reliableFieldOrder = reliableFieldOrder
        self.inputFormatSignature = inputFormatSignature
    }
}

enum VTVideoCodecProfile: UInt8, Sendable, Hashable {
    case h264High
    case hevcMain
    case hevcMain10

    var codecType: CMVideoCodecType {
        switch self {
        case .h264High: kCMVideoCodecType_H264
        case .hevcMain, .hevcMain10: kCMVideoCodecType_HEVC
        }
    }
}

enum VTVideoEncoderFailure: Error, Sendable, Equatable {
    case invalidDimensions
    case dimensionsExceeded
    case frameRateExceeded
    case unsupportedPixelFormat
    case inconsistentBitDepth
    case unknownMetadata
    case inconsistentHDRMetadata
    case invalidHDRMetadata
    case invalidPixelBuffer
    case invalidTime
    case generationMismatch
    case inputFormatChanged
    case unreliableFieldOrder
    case nonIncreasingPresentationTimestamp
    case backpressureExceeded
    case sessionCreate(OSStatus)
    case propertySet(String, OSStatus)
    case prepare(OSStatus)
    case hardwareEncoderNotActive
    case encode(OSStatus)
    case callback(OSStatus)
    case frameDropped
    case missingSampleBuffer
    case firstOutputNotSync
    case unexpectedOutputFormat
    case outputTimingMismatch
    case complete(OSStatus)
    case noEncodedOutput
    case cancelled
    case bitrateTargetExceeded
    case arithmeticOverflow
}

struct VTHardwareEncoderProof: Sendable, Hashable {
    let sessionID: VTCompressionSessionID
    let generation: MediaGeneration
    let firstOutputIdentity: VideoEncodingFrameIdentity
    let profile: VTVideoCodecProfile
}

struct HLSVideoEncodedOutput: @unchecked Sendable {
    let sourceIdentity: VideoEncodingFrameIdentity
    let sampleBuffer: CMSampleBuffer
    let presentationOrigin: PresentationOrigin
    let inputFormatSignature: VideoEncodingInputFormatSignature
    let hardwareProof: VTHardwareEncoderProof
}

struct HLSVideoEncoderFinishReceipt: Sendable, Equatable {
    let generation: MediaGeneration
    let encodedFrameCount: UInt64
    let hardwareProof: VTHardwareEncoderProof
}

enum HLSVideoEncoderTerminal: Sendable, Equatable {
    case finished
    case cancelled
    case failed(VTVideoEncoderFailure)
}

protocol HLSVideoEncoding: AnyObject, Sendable {
    func encode(
        frame: VideoEncodingFrame,
        completion: @escaping @Sendable (
            Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>
        ) -> Void
    )
    func finish(
        completion: @escaping @Sendable (
            Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>
        ) -> Void
    )
    /// 回调只在底层 native cancel/invalidate 已经在其实际 lane 执行完毕后触发。
    /// terminal 快照不是这份收据，调用者必须按 `false` fail-closed。
    func cancel(completion: @escaping @Sendable (Bool) -> Void)
    var terminal: HLSVideoEncoderTerminal? { get }
}

extension HLSVideoEncoding {
    func cancel() { cancel(completion: { _ in }) }
}

/// 一个编码 generation 的冻结码率合同，全部使用十进制 bit/s。
struct VTVideoBitratePolicy: Sendable, Hashable {
    static let maximumPayloadBitsPerSecond: UInt64 = 80_000_000
    static let minimumOverheadBitsPerSecond: UInt64 = 256_000

    let averageBitsPerSecond: UInt64
    let payloadBitsPerSecond: UInt64
    let dataRateLimitBytesPerSecond: UInt64
    let overheadBitsPerSecond: UInt64
    let declaredBitsPerSecond: UInt64

    static func freeze(
        firstTwoSecondsByteCount: UInt64,
        width: Int32,
        height: Int32,
        bitDepth: UInt8,
        dynamicRange: HLSVideoDynamicRange
    ) throws -> Self {
        guard width > 0, height > 0 else {
            throw VTVideoEncoderFailure.invalidDimensions
        }

        // 两秒窗口：bytes × 8 / 2，随后精确向上取整乘 1.10。
        let measured = try checkedMultiply(firstTwoSecondsByteCount, 4)
        let adjusted = try roundedUpRatio(measured, multiplier: 11, divisor: 10)
        let floor: UInt64
        if bitDepth > 8 || dynamicRange != .sdr {
            floor = 45_000_000
        } else if width > 1_920 || height > 1_080 {
            floor = 30_000_000
        } else if width > 1_280 || height > 720 {
            floor = 12_000_000
        } else {
            floor = 5_000_000
        }
        let average = max(adjusted, floor)
        let oneAndAHalf = try roundedUpRatio(average, multiplier: 3, divisor: 2)
        let plusFour = try checkedAdd(average, 4_000_000)
        let payload = min(maximumPayloadBitsPerSecond, max(oneAndAHalf, plusFour))
        guard average <= payload else { throw VTVideoEncoderFailure.bitrateTargetExceeded }
        let dataRateBytes = try roundedUpRatio(payload, multiplier: 1, divisor: 8)
        let overhead = max(
            minimumOverheadBitsPerSecond,
            try roundedUpRatio(payload, multiplier: 2, divisor: 100)
        )
        return Self(
            averageBitsPerSecond: average,
            payloadBitsPerSecond: payload,
            dataRateLimitBytesPerSecond: dataRateBytes,
            overheadBitsPerSecond: overhead,
            declaredBitsPerSecond: try checkedAdd(payload, overhead)
        )
    }

    private static func roundedUpRatio(
        _ value: UInt64,
        multiplier: UInt64,
        divisor: UInt64
    ) throws -> UInt64 {
        let product = try checkedMultiply(value, multiplier)
        let rounded = try checkedAdd(product, divisor - 1)
        return rounded / divisor
    }

    private static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw VTVideoEncoderFailure.arithmeticOverflow }
        return result.partialValue
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw VTVideoEncoderFailure.arithmeticOverflow }
        return result.partialValue
    }
}

struct VTVideoEncoderConfiguration: Sendable {
    let generation: MediaGeneration
    let inputFormat: VideoEncodingInputFormatSignature
    let frameRate: MediaRational
    let bitrate: VTVideoBitratePolicy
    let maximumPendingFrameCount: Int
}
