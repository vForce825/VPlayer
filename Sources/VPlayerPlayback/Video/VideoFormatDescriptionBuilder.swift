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
        parameterSetOwner: HLSVideoParameterSetRetention
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
        parameterSets: [Data]
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
                        extensions: nil,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }
        }
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
