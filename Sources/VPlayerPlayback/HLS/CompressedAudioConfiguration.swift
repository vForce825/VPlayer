// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum CompressedAudioConfigurationValidationError: Error, Sendable, Equatable {
    case invalidSourceFacts
    case invalidConfigurationBox
    case configurationMismatch
    case evidenceCapacityExceeded
}

struct AC3CompressedAudioConfiguration: Sendable, Hashable {
    let sampleRate: Int32
    let fscod: UInt8
    let bsid: UInt8
    let bsmod: UInt8
    let audioCodingMode: UInt8
    let hasLFE: Bool
    let bitRateCode: UInt8

    init(inspection: AC3FrameInspection) throws {
        guard inspection.sampleCount == 1_536,
              inspection.fscod < 3,
              inspection.bsid <= 31,
              inspection.bsmod < 8,
              inspection.acmod < 8,
              inspection.frmsizecod < 38 else {
            throw CompressedAudioConfigurationValidationError.invalidSourceFacts
        }
        sampleRate = inspection.sampleRate
        fscod = inspection.fscod
        bsid = inspection.bsid
        bsmod = inspection.bsmod
        audioCodingMode = inspection.acmod
        hasLFE = inspection.lfeon
        bitRateCode = inspection.frmsizecod >> 1
    }

    fileprivate init(
        sampleRate: Int32,
        fscod: UInt8,
        bsid: UInt8,
        bsmod: UInt8,
        audioCodingMode: UInt8,
        hasLFE: Bool,
        bitRateCode: UInt8
    ) throws {
        guard fscod < 3, bsid <= 31, bsmod < 8,
              audioCodingMode < 8, bitRateCode < 19 else {
            throw CompressedAudioConfigurationValidationError.invalidSourceFacts
        }
        self.sampleRate = sampleRate
        self.fscod = fscod
        self.bsid = bsid
        self.bsmod = bsmod
        self.audioCodingMode = audioCodingMode
        self.hasLFE = hasLFE
        self.bitRateCode = bitRateCode
    }

    fileprivate var box: Data {
        let payload = UInt32(fscod) << 22
            | UInt32(bsid) << 17
            | UInt32(bsmod) << 14
            | UInt32(audioCodingMode) << 11
            | UInt32(hasLFE ? 1 : 0) << 10
            | UInt32(bitRateCode) << 5
        return Data([
            0x00, 0x00, 0x00, 0x0B,
            0x64, 0x61, 0x63, 0x33,
            UInt8((payload >> 16) & 0xFF),
            UInt8((payload >> 8) & 0xFF),
            UInt8(payload & 0xFF),
        ])
    }

    fileprivate static func parse(box: Data, sampleRate: Int32) throws -> Self {
        guard box.count == 11,
              box[0...3] == dataLiteral(11),
              box[4...7] == Data([0x64, 0x61, 0x63, 0x33]) else {
            throw CompressedAudioConfigurationValidationError.invalidConfigurationBox
        }
        let payload = UInt32(box[8]) << 16 | UInt32(box[9]) << 8 | UInt32(box[10])
        guard payload & 0x1F == 0 else {
            throw CompressedAudioConfigurationValidationError.invalidConfigurationBox
        }
        return try Self(
            sampleRate: sampleRate,
            fscod: UInt8((payload >> 22) & 0x03),
            bsid: UInt8((payload >> 17) & 0x1F),
            bsmod: UInt8((payload >> 14) & 0x07),
            audioCodingMode: UInt8((payload >> 11) & 0x07),
            hasLFE: (payload >> 10) & 1 != 0,
            bitRateCode: UInt8((payload >> 5) & 0x1F)
        )
    }
}

struct EAC3CompressedAudioConfiguration: Sendable, Hashable {
    let sampleRate: Int32
    let fscod: UInt8
    let bsid: UInt8
    let bsmod: UInt8
    let audioCodingMode: UInt8
    let hasLFE: Bool
    let asvc: Bool
    let maximumDataRateKbps: UInt16

    init(
        sampleRate: Int32,
        bsid: UInt8,
        bsmod: UInt8,
        audioCodingMode: UInt8,
        hasLFE: Bool,
        asvc: Bool,
        maximumDataRateKbps: UInt16
    ) throws {
        let fscod: UInt8
        switch sampleRate {
        case 48_000: fscod = 0
        case 44_100: fscod = 1
        case 32_000: fscod = 2
        case 24_000, 22_050, 16_000: fscod = 3
        default: throw CompressedAudioConfigurationValidationError.invalidSourceFacts
        }
        guard (11...16).contains(bsid), bsmod < 8,
              audioCodingMode < 8, maximumDataRateKbps <= 8_191,
              !asvc else {
            throw CompressedAudioConfigurationValidationError.invalidSourceFacts
        }
        self.sampleRate = sampleRate
        self.fscod = fscod
        self.bsid = bsid
        self.bsmod = bsmod
        self.audioCodingMode = audioCodingMode
        self.hasLFE = hasLFE
        self.asvc = asvc
        self.maximumDataRateKbps = maximumDataRateKbps
    }

    private init(
        sampleRate: Int32,
        fscod: UInt8,
        bsid: UInt8,
        bsmod: UInt8,
        audioCodingMode: UInt8,
        hasLFE: Bool,
        asvc: Bool,
        maximumDataRateKbps: UInt16
    ) throws {
        guard fscod < 4, (11...16).contains(bsid), bsmod < 8,
              audioCodingMode < 8, maximumDataRateKbps <= 8_191,
              !asvc else {
            throw CompressedAudioConfigurationValidationError.invalidSourceFacts
        }
        self.sampleRate = sampleRate
        self.fscod = fscod
        self.bsid = bsid
        self.bsmod = bsmod
        self.audioCodingMode = audioCodingMode
        self.hasLFE = hasLFE
        self.asvc = asvc
        self.maximumDataRateKbps = maximumDataRateKbps
    }

    fileprivate var box: Data {
        let header = UInt16(maximumDataRateKbps) << 3 // 一个 independent substream 编码为零。
        let independent = UInt32(fscod) << 22
            | UInt32(bsid) << 17
            | UInt32(asvc ? 1 : 0) << 15
            | UInt32(bsmod) << 12
            | UInt32(audioCodingMode) << 9
            | UInt32(hasLFE ? 1 : 0) << 8
        // reserved、num_dep_sub 和 chan_loc/reserved 均为零。
        return Data([
            0x00, 0x00, 0x00, 0x0D,
            0x64, 0x65, 0x63, 0x33,
            UInt8((header >> 8) & 0xFF),
            UInt8(header & 0xFF),
            UInt8((independent >> 16) & 0xFF),
            UInt8((independent >> 8) & 0xFF),
            UInt8(independent & 0xFF),
        ])
    }

    fileprivate static func parse(box: Data, sampleRate: Int32) throws -> Self {
        guard box.count == 13,
              box[0...3] == dataLiteral(13),
              box[4...7] == Data([0x64, 0x65, 0x63, 0x33]) else {
            throw CompressedAudioConfigurationValidationError.invalidConfigurationBox
        }
        let header = UInt16(box[8]) << 8 | UInt16(box[9])
        let independent = UInt32(box[10]) << 16 | UInt32(box[11]) << 8 | UInt32(box[12])
        let numIndependentSubstreamsMinusOne = UInt8(header & 0x07)
        let reservedBeforeASVC = (independent >> 16) & 1
        let reservedAfterLFE = (independent >> 5) & 0x07
        let dependentSubstreamCount = (independent >> 1) & 0x0F
        let trailingReserved = independent & 1
        guard numIndependentSubstreamsMinusOne == 0,
              reservedBeforeASVC == 0,
              reservedAfterLFE == 0,
              dependentSubstreamCount == 0,
              trailingReserved == 0 else {
            throw CompressedAudioConfigurationValidationError.invalidConfigurationBox
        }
        return try Self(
            sampleRate: sampleRate,
            fscod: UInt8((independent >> 22) & 0x03),
            bsid: UInt8((independent >> 17) & 0x1F),
            bsmod: UInt8((independent >> 12) & 0x07),
            audioCodingMode: UInt8((independent >> 9) & 0x07),
            hasLFE: (independent >> 8) & 1 != 0,
            asvc: (independent >> 15) & 1 != 0,
            maximumDataRateKbps: header >> 3
        )
    }
}

enum CompressedAudioFormatConfiguration: Sendable, Hashable {
    case ac3(AC3CompressedAudioConfiguration)
    case eac3(EAC3CompressedAudioConfiguration)

    var codec: AudioCodec {
        switch self {
        case .ac3: .ac3
        case .eac3: .eac3
        }
    }

    var sampleRate: Int32 {
        switch self {
        case let .ac3(value): value.sampleRate
        case let .eac3(value): value.sampleRate
        }
    }

    var declaresDolbyAtmos: Bool { false }

    var serializedBox: Data {
        switch self {
        case let .ac3(value): value.box
        case let .eac3(value): value.box
        }
    }

    func validateFinalBoxes(_ boxes: [Data]) throws {
        guard boxes.count == 1 else {
            throw CompressedAudioConfigurationValidationError.invalidConfigurationBox
        }
        let parsed: Self
        switch self {
        case .ac3:
            parsed = .ac3(try AC3CompressedAudioConfiguration.parse(
                box: boxes[0],
                sampleRate: sampleRate
            ))
        case .eac3:
            parsed = .eac3(try EAC3CompressedAudioConfiguration.parse(
                box: boxes[0],
                sampleRate: sampleRate
            ))
        }
        guard parsed == self else {
            throw CompressedAudioConfigurationValidationError.configurationMismatch
        }
    }
}

private func dataLiteral(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ])
}

/// Facts read from one selected Core Audio Dolby cookie. This type cannot issue
/// a writer, timeline, emitted-initialization or route capability.
struct NativeDolbyAudioConfiguration: Sendable, Equatable {
    let codec: AudioCodec
    let profile: Int32
    let sampleRate: Int32
    let channelCount: Int32
    let backChannelMask: UInt64
    let sideChannelMask: UInt64
    let canonicalBox: Data

    static func parse(cookie: Data, codec: AudioCodec, sampleRate: Int32) throws -> Self {
        let box = try configurationBox(cookie, codec: codec)
        let mode: UInt8, lfe: Bool, profile: UInt8, factualRate: Int32
        switch codec {
        case .ac3:
            let config = try AC3CompressedAudioConfiguration.parse(box: box, sampleRate: sampleRate)
            guard config.bsid <= 10, config.bsmod == 0 else { throw CompressedAudioConfigurationValidationError.invalidSourceFacts }
            mode = config.audioCodingMode; lfe = config.hasLFE; profile = config.bsid
            factualRate = [Int32(48_000), 44_100, 32_000][Int(config.fscod)] >> max(Int(config.bsid) - 8, 0)
        case .eac3:
            let config = try EAC3CompressedAudioConfiguration.parse(box: box, sampleRate: sampleRate)
            // fscod3 omits the exact half-rate in dec3. Do not invent it from
            // the caller's ASBD; this bounded contract requires observed evidence.
            guard config.fscod < 3, config.bsmod == 0, !config.asvc else { throw CompressedAudioConfigurationValidationError.invalidSourceFacts }
            mode = config.audioCodingMode; lfe = config.hasLFE; profile = config.bsid
            factualRate = [Int32(48_000), 44_100, 32_000][Int(config.fscod)]
        default: throw CompressedAudioConfigurationValidationError.invalidSourceFacts
        }
        guard factualRate == sampleRate, (1...7).contains(mode) else { throw CompressedAudioConfigurationValidationError.configurationMismatch }
        let bases: [UInt64] = [0, 0x4, 0x3, 0x7, 0x103, 0x107, 0x33, 0x37]
        let back = bases[Int(mode)] | (lfe ? 0x8 : 0)
        let side = mode >= 6 ? (back & ~UInt64(0x30)) | 0x600 : back
        return .init(codec: codec, profile: Int32(profile), sampleRate: factualRate,
            channelCount: Int32(back.nonzeroBitCount), backChannelMask: back, sideChannelMask: side, canonicalBox: box)
    }
    func matches(_ source: HLSSourceAudioFacts, observedChannelMask: UInt64) -> Bool {
        guard source.formatValidated, source.service == .independentMain, source.codec == codec,
              source.profile == profile, source.sampleRate == sampleRate, source.channelCount == channelCount,
              source.channelMask == observedChannelMask,
              observedChannelMask == backChannelMask || observedChannelMask == sideChannelMask else { return false }
        if source.decoderConfiguration.isEmpty { return true }
        return (try? Self.configurationBox(source.decoderConfiguration, codec: codec)) == canonicalBox
    }
    /// Supported forms are a raw dac3/dec3 payload, one full atom, or the bounded
    /// Core Audio frma + atom cookie with its optional eight-byte terminator.
    private static func configurationBox(_ bytes: Data, codec: AudioCodec) throws -> Data {
        let type: [UInt8], wire: [UInt8], payloadCount: Int
        switch codec {
        case .ac3: type = [0x64, 0x61, 0x63, 0x33]; wire = [0x61, 0x63, 0x2D, 0x33]; payloadCount = 3
        case .eac3: type = [0x64, 0x65, 0x63, 0x33]; wire = [0x65, 0x63, 0x2D, 0x33]; payloadCount = 5
        default: throw CompressedAudioConfigurationValidationError.invalidSourceFacts
        }
        let count = payloadCount + 8
        if bytes.count == payloadCount { return Data([0, 0, 0, UInt8(count)] + type) + bytes }
        if bytes.count == count { return bytes }
        guard bytes.count == 12 + count || bytes.count == 12 + count + 8,
              bytes.prefix(12) == Data([0, 0, 0, 12, 0x66, 0x72, 0x6D, 0x61] + wire) else {
            throw CompressedAudioConfigurationValidationError.invalidConfigurationBox
        }
        if bytes.count == 12 + count + 8 {
            guard bytes.suffix(8) == Data([0, 0, 0, 8, 0, 0, 0, 0]) else {
                throw CompressedAudioConfigurationValidationError.invalidConfigurationBox
            }
        }
        return bytes.subdata(in: 12..<(12 + count))
    }
}
