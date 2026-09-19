// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import Foundation

enum RenditionChannelLabel: UInt8, Sendable, Hashable {
    case l, r, c, lfe, ls, rs, cs, rls, rrs, unknown, discrete, lc, height
}

struct RenditionAudioLayout: Sendable, Hashable {
    let labels: [RenditionChannelLabel]
    let tag: UInt32
    init(labels: [RenditionChannelLabel]) throws {
        guard Set(labels).count == labels.count,
              let row = Self.rows.first(where: { Set($0.0) == Set(labels) }) else {
            throw AACRenditionFailure.invalidLayout
        }
        self.labels = labels
        tag = row.1
    }
    init(native: AudioChannelLayout) throws {
        guard let mask = native.nativeMask, let labels = Self.nativeRows[mask],
              labels.count == native.channelCount else { throw AACRenditionFailure.invalidLayout }
        try self.init(labels: labels)
    }
    var canonical: Self { try! Self(labels: Self.rows.first { $0.1 == tag }!.0) }
    var audioToolbox: AudioToolbox.AudioChannelLayout {
        AudioToolbox.AudioChannelLayout(mChannelLayoutTag: tag, mChannelBitmap: [], mNumberChannelDescriptions: 0, mChannelDescriptions: (AudioChannelDescription(),))
    }
    // AAC 的逐行语义合同，不能以低 16 位声道数替代集合匹配。
    private static let rows: [([RenditionChannelLabel], UInt32)] = [
        ([.c], kAudioChannelLayoutTag_Mono),
        ([.l,.r], kAudioChannelLayoutTag_Stereo),
        ([.c,.l,.r], kAudioChannelLayoutTag_AAC_3_0),
        ([.l,.r,.ls,.rs], kAudioChannelLayoutTag_AAC_Quadraphonic),
        ([.c,.l,.r,.cs], kAudioChannelLayoutTag_AAC_4_0),
        ([.c,.l,.r,.ls,.rs], kAudioChannelLayoutTag_AAC_5_0),
        ([.c,.l,.r,.ls,.rs,.lfe], kAudioChannelLayoutTag_AAC_5_1),
        ([.c,.l,.r,.ls,.rs,.cs], kAudioChannelLayoutTag_AAC_6_0),
        ([.c,.l,.r,.ls,.rs,.cs,.lfe], kAudioChannelLayoutTag_AAC_6_1),
        ([.c,.l,.r,.ls,.rs,.rls,.rrs], kAudioChannelLayoutTag_AAC_7_0),
        ([.c,.l,.r,.ls,.rs,.rls,.rrs,.lfe], kAudioChannelLayoutTag_AAC_7_1_B),
    ]
    private static let nativeRows: [UInt64: [RenditionChannelLabel]] = [
        0x4:[.c], 0x3:[.l,.r], 0x7:[.l,.r,.c],
        0x33:[.l,.r,.ls,.rs], 0x603:[.l,.r,.ls,.rs],
        0x107:[.l,.r,.c,.cs],
        0x37:[.l,.r,.c,.ls,.rs], 0x607:[.l,.r,.c,.ls,.rs],
        0x3f:[.l,.r,.c,.lfe,.ls,.rs], 0x60f:[.l,.r,.c,.lfe,.ls,.rs],
        0x137:[.l,.r,.c,.ls,.rs,.cs], 0x707:[.l,.r,.c,.cs,.ls,.rs],
        0x13f:[.l,.r,.c,.lfe,.ls,.rs,.cs], 0x70f:[.l,.r,.c,.lfe,.cs,.ls,.rs],
        0x637:[.l,.r,.c,.rls,.rrs,.ls,.rs],
        0x63f:[.l,.r,.c,.lfe,.rls,.rrs,.ls,.rs],
    ]
}

struct StereoDownmixMatrixV1 {
    static let alpha = Double(bitPattern: 0x3FE6A09E667F3BCD)
    let gain: Double
    let left: [Double]
    let right: [Double]
    init(labels: [RenditionChannelLabel]) throws {
        _ = try RenditionAudioLayout(labels: labels)
        if labels == [.c] { gain = 1; left = [1]; right = [1]; return }
        let coefficients: [(Double, Double)] = labels.map {
            switch $0 {
            case .l: (1,0)
            case .r: (0,1)
            case .c,.cs: (Self.alpha,Self.alpha)
            case .ls,.rls: (Self.alpha,0)
            case .rs,.rrs: (0,Self.alpha)
            default: (0,0)
            }
        }
        // 固定 label 顺序累加，输入重排不能改变 binary64 的求和顺序。
        let canonical = try RenditionAudioLayout(labels: labels).canonical.labels
        var leftSum = 0.0, rightSum = 0.0
        for label in canonical {
            let item = coefficients[labels.firstIndex(of: label)!]
            leftSum += abs(item.0); rightSum += abs(item.1)
        }
        let fixedGain = 1 / max(leftSum, rightSum)
        gain = fixedGain
        left = coefficients.map { $0.0 * fixedGain }
        right = coefficients.map { $0.1 * fixedGain }
    }
}
