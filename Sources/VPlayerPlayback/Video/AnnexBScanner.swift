// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct AnnexBScanResult: Equatable {
    let lengthPrefixedData: Data
    let parameterSets: [Data]
}

enum AnnexBScanner {
    static let maximumAccessUnitBytes = 64 * 1_024 * 1_024
    static let invalidDataErrorCode: Int32 = -1_448_143_361

    static func scan(_ data: Data, codec: VideoCodec) throws -> AnnexBScanResult {
        guard !data.isEmpty, data.count <= maximumAccessUnitBytes else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        let bytes = [UInt8](data)
        let starts = startCodes(in: bytes)
        guard let first = starts.first,
              bytes[..<first.offset].allSatisfy({ $0 == 0 }) else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }

        var output = Data()
        var parameterSets: [Data] = []
        for index in starts.indices {
            let start = starts[index].offset + starts[index].length
            let untrimmedEnd = index + 1 < starts.count
                ? starts[index + 1].offset
                : bytes.count
            var end = untrimmedEnd
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            guard end > start else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            let nal = Data(bytes[start..<end])
            guard let length = UInt32(exactly: nal.count),
                  output.count <= maximumAccessUnitBytes - 4,
                  nal.count <= maximumAccessUnitBytes - output.count - 4 else {
                throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
            }
            var bigEndianLength = length.bigEndian
            Swift.withUnsafeBytes(of: &bigEndianLength) { output.append(contentsOf: $0) }
            output.append(nal)
            if isParameterSet(nal, codec: codec) {
                parameterSets.append(nal)
            }
        }
        guard !output.isEmpty else {
            throw PlaybackCoreError.videoDecode(invalidDataErrorCode)
        }
        return AnnexBScanResult(lengthPrefixedData: output, parameterSets: parameterSets)
    }

    private static func startCodes(in bytes: [UInt8]) -> [(offset: Int, length: Int)] {
        var result: [(Int, Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if index + 3 < bytes.count,
               bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 0,
               bytes[index + 3] == 1 {
                result.append((index, 4))
                index += 4
            } else if bytes[index] == 0,
                      bytes[index + 1] == 0,
                      bytes[index + 2] == 1 {
                result.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        return result
    }

    private static func isParameterSet(_ nal: Data, codec: VideoCodec) -> Bool {
        guard let first = nal.first else { return false }
        switch codec {
        case .h264:
            return [7, 8, 13].contains(first & 0x1F)
        case .hevc:
            return [32, 33, 34].contains((first >> 1) & 0x3F)
        }
    }
}
