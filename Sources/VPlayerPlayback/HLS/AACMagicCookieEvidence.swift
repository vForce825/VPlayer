// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct AACBandwidthEvidence: Sendable {
    let configuredBitrate: UInt32
    let payloadCeiling: UInt32
    let fmp4BodyCeiling: UInt32
    let peakPayloadBits: UInt64
    let accessUnitCount: UInt64
    let requiresWriterBodyAccounting: Bool
}
final class AACPayloadBandwidthWindow {
    private let configured: UInt32
    private let ceiling: UInt32
    private let lease: AACCalibrationWorkspace.Lease
    private var slots: [UInt64]
    private var head = 0, count = 0
    private var total: UInt64 = 0, peak: UInt64 = 0, units: UInt64 = 0
    var retainedCount: Int { count }
    var evidence: AACBandwidthEvidence {
        AACBandwidthEvidence(configuredBitrate: configured, payloadCeiling: ceiling, fmp4BodyCeiling: ceiling + 64_000,
            peakPayloadBits: peak, accessUnitCount: units, requiresWriterBodyAccounting: true)
    }
    static func ceiling(for bitrate: UInt32) throws -> UInt32 {
        let value = (UInt64(bitrate) * 5 + 3) / 4
        guard bitrate > 0, value <= UInt32.max - 64_000 else { throw AACRenditionFailure.invalidPlan }
        return UInt32(value)
    }
    init(configuredBitrate: UInt32, workspace: AACCalibrationWorkspace) throws {
        configured = configuredBitrate; ceiling = try Self.ceiling(for: configuredBitrate)
        lease = try workspace.acquire(.nonPayload, bytes: 1_024)
        slots = [UInt64](repeating: 0, count: 48)
    }
    func append(payloadBytes: Int, packetFrames: UInt32 = 1_024) throws {
        guard payloadBytes > 0, payloadBytes <= UInt32.max, packetFrames == 1_024,
              units < UInt64.max / 1_024 else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
        // AU 末端落在最近 48000-frame 窗口内；最多 47 AU，包含 priming/padding。
        let outgoing = count == 47 ? slots[head] : 0
        let bits = UInt64(payloadBytes) * 8
        let candidate = total - outgoing + bits
        guard candidate <= ceiling else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
        if count == 47 { head = (head + 1) % 48; count -= 1 }
        slots[(head + count) % 48] = bits
        count += 1; units += 1; total = candidate; peak = max(peak, total)
    }
}
final class AACMagicCookieEvidence {
    let backing: AACDataBacking
    let maximumBitrateRange: Range<Int>
    let maximumBitrate: UInt32
    let averageBitrate: UInt32
    let bufferSizeDB: UInt32
    let objectType: UInt8
    let streamTypeByte: UInt8
    let esID: UInt32
    let metadataLease: AACCalibrationWorkspace.Lease
    private let decoderRange: Range<Int>
    private let configuredBitrate: UInt32
    var decoderSpecificInfo: Data { backing.data.subdata(in: decoderRange) }

    init(backing: AACDataBacking, configuredBitrate: UInt32, workspace: AACCalibrationWorkspace,
         writerRepresentation: Bool = false) throws {
        self.backing = backing; self.configuredBitrate = configuredBitrate
        guard !backing.data.isEmpty, backing.data.count <= 524_288 else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
        metadataLease = try workspace.acquire(.nonPayload, bytes: 512)
        var cursor = Cursor(bytes: backing.data, fourByteLengths: !writerRepresentation)
        let es = try cursor.descriptor(tag: 3, parentEnd: backing.data.count)
        guard es.upperBound == backing.data.count else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
        esID = try cursor.integer(2, end: es.upperBound)
        guard try cursor.integer(1, end: es.upperBound) == 0 else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
        let decoder = try cursor.descriptor(tag: 4, parentEnd: es.upperBound)
        objectType = UInt8(try cursor.integer(1, end: decoder.upperBound))
        streamTypeByte = UInt8(try cursor.integer(1, end: decoder.upperBound))
        guard objectType == 0x40, streamTypeByte == 0x14 || (writerRepresentation && streamTypeByte == 0x15) else {
            throw AACRenditionFailure.aacEncoderCookieInvariantViolation
        }
        bufferSizeDB = try cursor.integer(3, end: decoder.upperBound)
        maximumBitrateRange = cursor.position..<(cursor.position + 4)
        maximumBitrate = try cursor.integer(4, end: decoder.upperBound)
        averageBitrate = try cursor.integer(4, end: decoder.upperBound)
        guard maximumBitrate <= (try AACPayloadBandwidthWindow.ceiling(for: configuredBitrate)) else {
            throw AACRenditionFailure.aacEncoderCookieInvariantViolation
        }
        decoderRange = try cursor.descriptor(tag: 5, parentEnd: decoder.upperBound)
        guard decoderRange.count >= 2, decoderRange.count <= 256,
              decoderRange.upperBound == decoder.upperBound else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
        // ASC 包括多声道 PCE 时保持完整原字节；这里只接受请求域内的 AAC-LC/48kHz 前缀。
        let first = backing.data[decoderRange.lowerBound], second = backing.data[decoderRange.lowerBound + 1]
        guard first >> 3 == 2, ((first & 7) << 1 | second >> 7) == 3 else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
        cursor.position = decoderRange.upperBound
        let sl = try cursor.descriptor(tag: 6, parentEnd: es.upperBound)
        guard sl.count == 1, try cursor.integer(1, end: sl.upperBound) == 2,
              cursor.position == es.upperBound else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
    }
    func validateLive(_ live: AACMagicCookieEvidence) throws {
        let a = backing.data, b = live.backing.data, range = maximumBitrateRange
        guard configuredBitrate == live.configuredBitrate, range == live.maximumBitrateRange,
              a.count == b.count, a.prefix(range.lowerBound) == b.prefix(range.lowerBound),
              a.suffix(from: range.upperBound) == b.suffix(from: range.upperBound) else {
            throw AACRenditionFailure.aacEncoderCookieInvariantViolation
        }
    }
    func validateWriterDecoderConfiguration(_ writer: AACMagicCookieEvidence) throws {
        guard objectType == writer.objectType, streamTypeByte >> 2 == writer.streamTypeByte >> 2,
              decoderSpecificInfo == writer.decoderSpecificInfo else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
    }
    private struct Cursor {
        let bytes: Data
        let fourByteLengths: Bool
        var position = 0
        mutating func integer(_ count: Int, end: Int) throws -> UInt32 {
            guard count > 0, count <= 4, position <= end - count, end <= bytes.count else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
            var value: UInt32 = 0
            for _ in 0..<count { value = value << 8 | UInt32(bytes[position]); position += 1 }
            return value
        }
        mutating func descriptor(tag: UInt32, parentEnd: Int) throws -> Range<Int> {
            guard try integer(1, end: parentEnd) == tag else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
            var size: UInt32 = 0, width = 0
            while true {
                let byte = try integer(1, end: parentEnd); width += 1
                size = size << 7 | byte & 0x7f
                if byte & 0x80 == 0 { break }
                guard width < 4 else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
            }
            guard !fourByteLengths || width == 4, size <= 524_288,
                  Int(size) <= parentEnd - position else { throw AACRenditionFailure.aacEncoderCookieInvariantViolation }
            return position..<(position + Int(size))
        }
    }
}

// 只沿单音轨 moov/trak/mdia/minf/stbl/stsd/mp4a/esds 路径读取实际封装，绝不扫描 mdat 的偶然字节。
enum AACWriterESDS {
    static func extract(from data: Data) throws -> Data {
        func integer(_ offset: Int, _ width: Int) throws -> UInt64 {
            guard offset >= 0, width <= data.count, offset <= data.count - width else { throw AACRenditionFailure.calibrationMismatch }
            return data[offset..<(offset + width)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func child(_ tag: UInt32, in range: Range<Int>) throws -> Range<Int> {
            var offset = range.lowerBound, found: Range<Int>?, count = 0
            while offset < range.upperBound {
                guard range.upperBound - offset >= 8, count < 256 else { throw AACRenditionFailure.calibrationMismatch }
                count += 1
                let small = try integer(offset, 4), type = try integer(offset + 4, 4)
                let header = small == 1 ? 16 : 8
                let size = small == 0 ? UInt64(range.upperBound - offset) : small == 1 ? try integer(offset + 8, 8) : small
                guard size >= header, size <= range.upperBound - offset else { throw AACRenditionFailure.calibrationMismatch }
                if type == tag {
                    guard found == nil else { throw AACRenditionFailure.calibrationMismatch }
                    found = (offset + header)..<(offset + Int(size))
                }
                offset += Int(size)
            }
            guard offset == range.upperBound, let found else { throw AACRenditionFailure.calibrationMismatch }
            return found
        }
        var range = 0..<data.count
        for tag: UInt32 in [0x6d6f6f76,0x7472616b,0x6d646961,0x6d696e66,0x7374626c,0x73747364] { range = try child(tag, in: range) }
        guard range.count >= 8, try integer(range.lowerBound, 4) == 0, try integer(range.lowerBound + 4, 4) == 1 else { throw AACRenditionFailure.calibrationMismatch }
        range = try child(0x6d703461, in: (range.lowerBound + 8)..<range.upperBound)
        guard range.count >= 28 else { throw AACRenditionFailure.calibrationMismatch }
        range = try child(0x65736473, in: (range.lowerBound + 28)..<range.upperBound)
        guard range.count >= 4, try integer(range.lowerBound, 4) == 0 else { throw AACRenditionFailure.calibrationMismatch }
        return data.subdata(in: (range.lowerBound + 4)..<range.upperBound)
    }
}
