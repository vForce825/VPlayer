// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum VideoFormatDescriptionBuilder {
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
            switch codec {
            case .h264:
                return stablePointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        guard let pointerBase = pointerBuffer.baseAddress,
                              let sizeBase = sizeBuffer.baseAddress else {
                            return kCMFormatDescriptionError_InvalidParameter
                        }
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: parameterSets.count,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            case .hevc:
                return stablePointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        guard let pointerBase = pointerBuffer.baseAddress,
                              let sizeBase = sizeBuffer.baseAddress else {
                            return kCMFormatDescriptionError_InvalidParameter
                        }
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: parameterSets.count,
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
        guard status == noErr, let formatDescription else {
            throw PlaybackCoreError.videoFormatDescription(status)
        }
        return formatDescription
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
