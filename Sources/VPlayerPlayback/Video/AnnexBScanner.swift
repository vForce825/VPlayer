// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct AnnexBScanResult: Equatable {
    let lengthPrefixedData: Data
    let parameterSets: [Data]
    let randomAccessKind: VideoRandomAccessKind
}

public enum VideoRandomAccessKind: UInt8, Sendable, Hashable {
    case none
    case h264IDR
    case hevcIDR
    case hevcCRA
    case containerKey
}

struct AnnexBNALUnitView: Sendable, Equatable {
    let byteRange: VideoAccessUnitByteRange
    let nalUnitType: UInt8
    let isParameterSet: Bool
    let randomAccessKind: VideoRandomAccessKind
}

enum AnnexBScanner {
    static let maximumAccessUnitBytes = 64 * 1_024 * 1_024
    static let maximumNALUnitCount = 65_536
    static let maximumParameterSetCount = 64
    static let maximumParameterSetBytes = 1 * 1_024 * 1_024
    static let invalidDataErrorCode: Int32 = -1_448_143_361

    static func scan(_ data: Data, codec: VideoCodec) throws -> AnnexBScanResult {
        try scan(data.span, baseOffset: 0, codec: codec)
    }

    /// 临时 bridge：先复用 legacy scanner 的严格校验和实际输出长度，让目标可
    /// 运行；完整 HLS 接线随后会改成无 Data 逃逸的 checked 测量/预分配。
    static func measureLengthPrefixedOutput(
        _ bytes: borrowing Span<UInt8>,
        codec: VideoCodec
    ) throws -> (lengthPrefixedBytes: Int, parameterSetBytes: Int, parameterSetCount: Int) {
        var outputBytes = 0, parameterSetBytes = 0, parameterSetCount = 0
        try enumerate(bytes, baseOffset: 0, codec: codec) { view, nal in
            let output = outputBytes.addingReportingOverflow(4)
            let payload = output.partialValue.addingReportingOverflow(nal.count)
            guard !output.overflow, !payload.overflow,
                  payload.partialValue <= maximumAccessUnitBytes else { throw invalidDataError() }
            outputBytes = payload.partialValue
            if view.isParameterSet {
                let total = parameterSetBytes.addingReportingOverflow(nal.count)
                guard !total.overflow else { throw invalidDataError() }
                parameterSetBytes = total.partialValue
                parameterSetCount += 1
            }
        }
        guard outputBytes > 0 else { throw invalidDataError() }
        return (outputBytes, parameterSetBytes, parameterSetCount)
    }

    static func scan(
        _ bytes: borrowing Span<UInt8>,
        codec: VideoCodec
    ) throws -> AnnexBScanResult {
        try scan(bytes, baseOffset: 0, codec: codec)
    }

    /// 调用方已通过 `measureLengthPrefixedOutput` 取得准入时，使用精确容量避免
    /// Data/参数数组在已支付 envelope 之外自行增长。
    static func scan(
        _ bytes: borrowing Span<UInt8>,
        codec: VideoCodec,
        outputCapacity: Int,
        parameterSetCapacity: Int
    ) throws -> AnnexBScanResult {
        try scan(
            bytes,
            baseOffset: 0,
            codec: codec,
            outputCapacity: outputCapacity,
            parameterSetCapacity: parameterSetCapacity
        )
    }

    static func scan(
        _ backing: VideoAccessUnitBacking,
        range: VideoAccessUnitByteRange,
        codec: VideoCodec
    ) throws -> AnnexBScanResult {
        try backing.withBytes(in: range) { bytes in
            try scan(bytes, baseOffset: range.offset, codec: codec)
        }
    }

    /// visitor 在 backing 的借用期内同步执行，Span 由编译器禁止逃逸。
    static func visitNALUnits(
        in backing: VideoAccessUnitBacking,
        range: VideoAccessUnitByteRange,
        codec: VideoCodec,
        _ visitor: (AnnexBNALUnitView, borrowing Span<UInt8>) throws -> Void
    ) throws {
        try backing.withBytes(in: range) { bytes in
            try enumerate(bytes, baseOffset: range.offset, codec: codec, visitor)
        }
    }

    static func scan(
        _ bytes: borrowing Span<UInt8>,
        baseOffset: Int,
        codec: VideoCodec
    ) throws -> AnnexBScanResult {
        try scan(bytes, baseOffset: baseOffset, codec: codec, outputCapacity: nil, parameterSetCapacity: nil)
    }

    private static func scan(
        _ bytes: borrowing Span<UInt8>,
        baseOffset: Int,
        codec: VideoCodec,
        outputCapacity: Int?,
        parameterSetCapacity: Int?
    ) throws -> AnnexBScanResult {
        var output = Data()
        var parameterSets: [Data] = []
        if let outputCapacity { output.reserveCapacity(outputCapacity) }
        if let parameterSetCapacity { parameterSets.reserveCapacity(parameterSetCapacity) }
        var randomAccessKind = VideoRandomAccessKind.none

        try enumerate(bytes, baseOffset: baseOffset, codec: codec) { view, nal in
            guard let length = UInt32(exactly: nal.count),
                  output.count <= maximumAccessUnitBytes - 4,
                  nal.count <= maximumAccessUnitBytes - output.count - 4 else {
                throw invalidDataError()
            }
            var bigEndianLength = length.bigEndian
            Swift.withUnsafeBytes(of: &bigEndianLength) { output.append(contentsOf: $0) }
            nal.withUnsafeBytes { output.append(contentsOf: $0) }
            if view.isParameterSet {
                parameterSets.append(nal.withUnsafeBytes { Data($0) })
            }
            switch view.randomAccessKind {
            case .h264IDR, .hevcIDR:
                randomAccessKind = view.randomAccessKind
            case .hevcCRA where randomAccessKind == .none:
                randomAccessKind = .hevcCRA
            case .none, .containerKey, .hevcCRA:
                break
            }
        }
        guard !output.isEmpty else { throw invalidDataError() }
        return AnnexBScanResult(
            lengthPrefixedData: output,
            parameterSets: parameterSets,
            randomAccessKind: randomAccessKind
        )
    }

    private static func enumerate(
        _ bytes: borrowing Span<UInt8>,
        baseOffset: Int,
        codec: VideoCodec,
        _ visitor: (AnnexBNALUnitView, borrowing Span<UInt8>) throws -> Void
    ) throws {
        guard !bytes.isEmpty, bytes.count <= maximumAccessUnitBytes,
              let first = findStartCode(in: bytes, startingAt: 0) else {
            throw invalidDataError()
        }
        for index in 0..<first.offset where bytes[index] != 0 {
            throw invalidDataError()
        }

        var current = first
        var nalCount = 0
        var parameterSetCount = 0
        var parameterSetBytes = 0
        while true {
            let payloadStart = current.offset + current.length
            let next = findStartCode(in: bytes, startingAt: payloadStart)
            var payloadEnd = next?.offset ?? bytes.count
            while payloadEnd > payloadStart, bytes[payloadEnd - 1] == 0 {
                payloadEnd -= 1
            }
            guard payloadEnd > payloadStart else { throw invalidDataError() }

            let nal = bytes.extracting(payloadStart..<payloadEnd)
            guard hasValidHeaderAndPayload(nal, codec: codec) else {
                throw invalidDataError()
            }
            nalCount += 1
            guard nalCount <= maximumNALUnitCount else { throw invalidDataError() }

            let type = nalUnitType(nal, codec: codec)
            let parameterSet = isParameterSet(type, codec: codec)
            if parameterSet {
                parameterSetCount += 1
                let (newByteCount, overflowed) = parameterSetBytes.addingReportingOverflow(nal.count)
                guard !overflowed,
                      parameterSetCount <= maximumParameterSetCount,
                      newByteCount <= maximumParameterSetBytes else {
                    throw invalidDataError()
                }
                parameterSetBytes = newByteCount
            }
            let (absoluteOffset, offsetOverflowed) = baseOffset.addingReportingOverflow(payloadStart)
            guard !offsetOverflowed,
                  let byteRange = VideoAccessUnitByteRange(
                    offset: absoluteOffset,
                    length: nal.count
                  ) else {
                throw invalidDataError()
            }
            try visitor(AnnexBNALUnitView(
                byteRange: byteRange,
                nalUnitType: type,
                isParameterSet: parameterSet,
                randomAccessKind: accessKind(type, codec: codec)
            ), nal)

            guard let next else { return }
            current = next
        }
    }

    private static func findStartCode(
        in bytes: borrowing Span<UInt8>,
        startingAt start: Int
    ) -> (offset: Int, length: Int)? {
        var index = start
        while index + 2 < bytes.count {
            if index + 3 < bytes.count,
               bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 0,
               bytes[index + 3] == 1 {
                return (index, 4)
            }
            if bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 1 {
                return (index, 3)
            }
            index += 1
        }
        return nil
    }

    private static func nalUnitType(
        _ nal: borrowing Span<UInt8>,
        codec: VideoCodec
    ) -> UInt8 {
        switch codec {
        case .h264:
            return nal[0] & 0x1F
        case .hevc:
            return (nal[0] >> 1) & 0x3F
        }
    }

    private static func isParameterSet(_ type: UInt8, codec: VideoCodec) -> Bool {
        switch codec {
        case .h264:
            return type == 7 || type == 8 || type == 13
        case .hevc:
            return type == 32 || type == 33 || type == 34
        }
    }

    private static func hasValidHeaderAndPayload(
        _ nal: borrowing Span<UInt8>,
        codec: VideoCodec
    ) -> Bool {
        guard !nal.isEmpty else { return false }
        let first = nal[0]
        guard first & 0x80 == 0 else { return false }
        switch codec {
        case .h264:
            let type = first & 0x1F
            return !(1...5).contains(type) || nal.count > 1
        case .hevc:
            guard nal.count >= 2, nal[1] & 0x07 != 0 else { return false }
            let type = (first >> 1) & 0x3F
            return type > 31 || nal.count > 2
        }
    }

    private static func accessKind(
        _ type: UInt8,
        codec: VideoCodec
    ) -> VideoRandomAccessKind {
        switch codec {
        case .h264:
            return type == 5 ? .h264IDR : .none
        case .hevc:
            switch type {
            case 19, 20: return .hevcIDR
            case 21: return .hevcCRA
            default: return .none
            }
        }
    }

    private static func invalidDataError() -> PlaybackCoreError {
        .videoDecode(invalidDataErrorCode)
    }
}
