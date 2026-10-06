// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum VideoFormatDescriptionBuilder {
    /// HLS 参数集由 snapshot owner 持有。所有指针只在逐层 `withBytes` 的
    /// 借用栈中存在，绝不能先收集后离开某个 Entry 的借用窗口。
    static func make(
        codec: VideoCodec,
        parameterSetOwner: HLSVideoParameterSetRetention,
        videoMetadata: DemuxVideoMetadata = DemuxVideoMetadata()
    ) throws -> CMVideoFormatDescription {
        let entries = parameterSetOwner.entries
        guard !entries.isEmpty, entries.allSatisfy({ $0.byteCount > 0 }) else {
            throw PlaybackCoreError.videoFormatDescription(kCMFormatDescriptionError_InvalidParameter)
        }
        let workspaceBytes = try checkedPointerWorkspaceBytes(entries.count)
        return try parameterSetOwner.withTemporaryCanonicalWorkspace(bytes: workspaceBytes) {
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            pointers.reserveCapacity(entries.count)
            sizes.reserveCapacity(entries.count)
            var formatDescription: CMFormatDescription?
            let status = try withOwnerParameterSetPointers(
                entries,
                pointers: &pointers,
                sizes: &sizes,
                index: 0
            ) { stablePointers, stableSizes in
                create(
                    codec: codec,
                    pointers: stablePointers,
                    sizes: stableSizes,
                    extensions: try colorExtensions(videoMetadata),
                    formatDescription: &formatDescription
                )
            }
            guard status == noErr, let formatDescription else {
                throw PlaybackCoreError.videoFormatDescription(status)
            }
            return formatDescription
        }
    }

    static func make(
        codec: VideoCodec,
        parameterSets: [Data],
        videoMetadata: DemuxVideoMetadata = DemuxVideoMetadata()
    ) throws -> CMVideoFormatDescription {
        guard !parameterSets.isEmpty, parameterSets.allSatisfy({ !$0.isEmpty }) else {
            throw PlaybackCoreError.videoFormatDescription(kCMFormatDescriptionError_InvalidParameter)
        }
        var pointers: [UnsafePointer<UInt8>] = []
        let sizes = parameterSets.map(\.count)
        var formatDescription: CMFormatDescription?

        let status = try withParameterSetPointers(
            parameterSets,
            pointers: &pointers,
            index: 0
        ) { stablePointers in
            create(
                codec: codec,
                pointers: stablePointers,
                sizes: sizes,
                extensions: try colorExtensions(videoMetadata),
                formatDescription: &formatDescription
            )
        }
        guard status == noErr, let formatDescription else {
            throw PlaybackCoreError.videoFormatDescription(status)
        }
        return formatDescription
    }

    private static func create(
        codec: VideoCodec,
        pointers: [UnsafePointer<UInt8>],
        sizes: [Int],
        extensions: CFDictionary?,
        formatDescription: inout CMFormatDescription?
    ) -> OSStatus {
        pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                guard let pointerBase = pointerBuffer.baseAddress,
                      let sizeBase = sizeBuffer.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                switch codec {
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDescription
                    )
                case .hevc:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase,
                        nalUnitHeaderLength: 4,
                        extensions: extensions,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }
        }
    }

    /// 解复用器会结合 SEI 解析有效传递函数；只从 SPS 重建会把兼容写法的 HLG
    /// 当作 SDR。显式传递已有色彩证据，缺失的字段继续交给 Core Media 解析。
    private static func colorExtensions(_ metadata: DemuxVideoMetadata) throws -> CFDictionary? {
        var result: [String: Any] = [:]
        if let range = metadata.range {
            result[kCMFormatDescriptionExtension_FullRangeVideo as String] = range == .full
        }
        if let primaries = metadata.primaries {
            result[kCMFormatDescriptionExtension_ColorPrimaries as String] = switch primaries {
            case .bt470BG, .smpte170M: throw PlaybackCoreError.videoFormatDescription(kCMFormatDescriptionError_InvalidParameter)
            case .bt709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            case .bt2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020
            }
        }
        if let transfer = metadata.transfer {
            result[kCMFormatDescriptionExtension_TransferFunction as String] = switch transfer {
            case .smpte170M: throw PlaybackCoreError.videoFormatDescription(kCMFormatDescriptionError_InvalidParameter)
            case .bt709: kCMFormatDescriptionTransferFunction_ITU_R_709_2
            case .bt2020, .bt2020_12: kCMFormatDescriptionTransferFunction_ITU_R_2020
            case .pq: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            case .hlg: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            }
        }
        if let matrix = metadata.matrix {
            result[kCMFormatDescriptionExtension_YCbCrMatrix as String] = switch matrix {
            case .bt470BG, .smpte170M: throw PlaybackCoreError.videoFormatDescription(kCMFormatDescriptionError_InvalidParameter)
            case .bt709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            case .bt2020Nonconstant: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
            }
        }
        return result.isEmpty ? nil : result as CFDictionary
    }

    private static func checkedPointerWorkspaceBytes(_ count: Int) throws -> Int {
        let pointerBytes = count.multipliedReportingOverflow(by: MemoryLayout<UnsafePointer<UInt8>>.stride)
        let sizeBytes = count.multipliedReportingOverflow(by: MemoryLayout<Int>.stride)
        let total = pointerBytes.partialValue.addingReportingOverflow(sizeBytes.partialValue)
        guard !pointerBytes.overflow, !sizeBytes.overflow, !total.overflow, total.partialValue > 0 else {
            throw PlaybackCoreError.videoFormatDescription(kCMFormatDescriptionError_InvalidParameter)
        }
        return total.partialValue
    }

    private static func withOwnerParameterSetPointers<Result>(
        _ entries: [HLSVideoParameterSetRetention.Entry],
        pointers: inout [UnsafePointer<UInt8>],
        sizes: inout [Int],
        index: Int,
        body: ([UnsafePointer<UInt8>], [Int]) throws -> Result
    ) throws -> Result {
        guard index < entries.count else { return try body(pointers, sizes) }
        return try entries[index].withBytes { bytes in
            guard let baseAddress = bytes.withUnsafeBytes({
                $0.baseAddress?.assumingMemoryBound(to: UInt8.self)
            }) else {
                throw PlaybackCoreError.videoFormatDescription(kCMFormatDescriptionError_InvalidParameter)
            }
            pointers.append(baseAddress)
            sizes.append(bytes.count)
            defer { pointers.removeLast(); sizes.removeLast() }
            return try withOwnerParameterSetPointers(
                entries,
                pointers: &pointers,
                sizes: &sizes,
                index: index + 1,
                body: body
            )
        }
    }

    private static func withParameterSetPointers<Result>(
        _ parameterSets: [Data],
        pointers: inout [UnsafePointer<UInt8>],
        index: Int,
        body: ([UnsafePointer<UInt8>]) throws -> Result
    ) throws -> Result {
        guard index < parameterSets.count else { return try body(pointers) }
        return try parameterSets[index].withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw PlaybackCoreError.videoFormatDescription(
                    kCMFormatDescriptionError_InvalidParameter
                )
            }
            pointers.append(baseAddress)
            defer { pointers.removeLast() }
            return try withParameterSetPointers(
                parameterSets,
                pointers: &pointers,
                index: index + 1,
                body: body
            )
        }
    }
}
