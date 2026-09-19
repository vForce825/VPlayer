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
