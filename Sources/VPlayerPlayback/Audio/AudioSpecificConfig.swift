// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct AudioSpecificConfig: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case aacLC
        case heAACv1
        case heAACv2
    }

    private static let sampleRates: [Int32] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
        22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]
    private static let channelCounts: [Int32] = [0, 1, 2, 3, 4, 5, 6, 8]
    private static let maximumBytes = 64

    let kind: Kind
    let outputSampleRate: Int32
    let outputChannelCount: Int32
    let bytes: Data

    private init(
        kind: Kind,
        outputSampleRate: Int32,
        outputChannelCount: Int32,
        bytes: Data
    ) {
        self.kind = kind
        self.outputSampleRate = outputSampleRate
        self.outputChannelCount = outputChannelCount
        self.bytes = bytes
    }

    var coreAudioMagicCookie: Data {
        // parse 已把 ASC 限制在 64 字节内，所有 descriptor 长度都只需一个字节。
        var cookie = Data([
            0x03, UInt8(23 + bytes.count), 0x00, 0x00, 0x00,
            0x04, UInt8(15 + bytes.count), 0x40, 0x15,
            0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x05, UInt8(bytes.count),
        ])
        cookie.append(bytes)
        cookie.append(contentsOf: [0x06, 0x01, 0x02])
        return cookie
    }

    static func parse(_ data: Data) throws -> AudioSpecificConfig {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw AudioCodecProfileValidation.error()
        }
        var reader = BoundedBitReader(data: data)
        let outerObjectType = try readObjectType(from: &reader)
        let coreSampleRate = try readSampleRate(from: &reader)
        let channelConfiguration = try reader.read(4)
        guard channelConfiguration > 0,
              channelConfiguration < channelCounts.count else {
            throw AudioCodecProfileValidation.error()
        }
        let coreChannelCount = channelCounts[channelConfiguration]

        let kind: Kind
        let outputSampleRate: Int32
        let outputChannelCount: Int32
        switch outerObjectType {
        case 2:
            kind = .aacLC
            outputSampleRate = coreSampleRate
            outputChannelCount = coreChannelCount
        case 5, 29:
            outputSampleRate = try readSampleRate(from: &reader)
            let coreObjectType = try readObjectType(from: &reader)
            let (expectedOutputSampleRate, overflow) = coreSampleRate.multipliedReportingOverflow(by: 2)
            guard coreObjectType == 2,
                  !overflow,
                  outputSampleRate == expectedOutputSampleRate else {
                throw AudioCodecProfileValidation.error()
            }
            if outerObjectType == 29 {
                guard coreChannelCount == 1 else {
                    throw AudioCodecProfileValidation.error()
                }
                kind = .heAACv2
                outputChannelCount = 2
            } else {
                kind = .heAACv1
                outputChannelCount = coreChannelCount
            }
        default:
            throw AudioCodecProfileValidation.error()
        }

        let frameLengthFlag = try reader.read(1)
        let dependsOnCoreCoder = try reader.read(1)
        let extensionFlag = try reader.read(1)
        guard frameLengthFlag == 0,
              dependsOnCoreCoder == 0,
              extensionFlag == 0,
              reader.remainingBitCount <= 7,
              try reader.remainingBitsAreZero() else {
            throw AudioCodecProfileValidation.error()
        }

        return AudioSpecificConfig(
            kind: kind,
            outputSampleRate: outputSampleRate,
            outputChannelCount: outputChannelCount,
            bytes: data
        )
    }

    private static func readObjectType(from reader: inout BoundedBitReader) throws -> Int {
        let base = try reader.read(5)
        if base == 31 {
            return 32 + (try reader.read(6))
        }
        return base
    }

    private static func readSampleRate(from reader: inout BoundedBitReader) throws -> Int32 {
        let index = try reader.read(4)
        if index == 15 {
            let explicit = try reader.read(24)
            guard explicit > 0, let result = Int32(exactly: explicit) else {
                throw AudioCodecProfileValidation.error()
            }
            return result
        }
        guard index < sampleRates.count else {
            throw AudioCodecProfileValidation.error()
        }
        return sampleRates[index]
    }
}

private struct BoundedBitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(data: Data) {
        bytes = [UInt8](data)
    }

    var remainingBitCount: Int {
        bytes.count * 8 - bitOffset
    }

    mutating func read(_ count: Int) throws -> Int {
        guard count >= 0, count <= 24, remainingBitCount >= count else {
            throw AudioCodecProfileValidation.error()
        }
        var result = 0
        for _ in 0..<count {
            let byteIndex = bitOffset / 8
            let bitIndex = 7 - bitOffset % 8
            result = result << 1 | Int((bytes[byteIndex] >> bitIndex) & 1)
            bitOffset += 1
        }
        return result
    }

    mutating func remainingBitsAreZero() throws -> Bool {
        while remainingBitCount > 0 {
            if try read(1) != 0 { return false }
        }
        return true
    }
}
