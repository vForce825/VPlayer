// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// RFC6381 declarations are compared with observed scalar facts, including all
/// profile-compatibility and constraint bits. A recognized codec name is not proof.
enum HLSDeclaredCodec: Equatable {
    case avc(entry: String, profile: UInt8, compatibility: UInt8, level: UInt8)
    case hevc(entry: String, profile: Int32, compatibility: UInt32, tier: HLSVideoTier, level: UInt8, constraints: UInt64)
    case aac(profile: Int32)
    case ac3, eac3, webVTT

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first else { return nil }
        switch name {
        case "avc1", "avc3":
            guard parts.count == 2, parts[1].utf8.count == 6, let bits = UInt32(parts[1], radix: 16) else { return nil }
            self = .avc(entry: name, profile: UInt8(bits >> 16), compatibility: UInt8((bits >> 8) & 255), level: UInt8(bits & 255))
        case "hvc1", "hev1":
            guard (4...10).contains(parts.count), !parts[1].isEmpty,
                  parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let profile = Int32(parts[1]), (1...31).contains(profile),
                  (1...8).contains(parts[2].utf8.count), let flags = UInt32(parts[2], radix: 16),
                  let first = parts[3].first, first == "L" || first == "H",
                  let level = UInt8(parts[3].dropFirst()), level > 0 else { return nil }
            var constraints: UInt64 = 0
            for (index, value) in parts.dropFirst(4).enumerated() {
                guard (1...2).contains(value.utf8.count), let byte = UInt8(value, radix: 16) else { return nil }
                constraints |= UInt64(byte) << (40 - index * 8)
            }
            var raw: UInt32 = 0
            for bit in 0..<32 { raw |= ((flags >> bit) & 1) << (31 - bit) }
            self = .hevc(entry: name, profile: profile, compatibility: raw, tier: first == "L" ? .main : .high, level: level, constraints: constraints)
        case "mp4a":
            guard parts.count == 3, parts[1] == "40" else { return nil }
            switch parts[2] { case "2": self = .aac(profile: 1); case "5": self = .aac(profile: 4); case "29": self = .aac(profile: 28); default: return nil }
        case "ac-3": guard parts.count == 1 else { return nil }; self = .ac3
        case "ec-3": guard parts.count == 1 else { return nil }; self = .eac3
        case "wvtt": guard parts.count == 1 else { return nil }; self = .webVTT
        default: return nil
        }
    }
    func matches(video: HLSVideoFacts) -> Bool {
        guard video.parameterSetsValidated else { return false }
        switch self {
        case let .avc(entry, profile, compatibility, level):
            return video.codec == .h264 && video.profile == Int32(profile) && video.compatibilityFlags == UInt32(compatibility) && video.level == level && (video.sampleEntry == nil || video.sampleEntry == entry)
        case let .hevc(entry, profile, compatibility, tier, level, constraints):
            return video.codec == .hevc && video.profile == profile && video.compatibilityFlags == compatibility && video.tier == tier && video.level == level && video.constraintIndicatorFlags == constraints && video.sampleEntry == entry
        default: return false
        }
    }
    func matches(audio: HLSSourceAudioFacts) -> Bool {
        guard audio.formatValidated else { return false }
        switch self {
        case let .aac(profile): return audio.codec == .aac && audio.profile == profile
        case .ac3: return audio.codec == .ac3 && (0...10).contains(audio.profile)
        case .eac3: return audio.codec == .eac3 && (11...16).contains(audio.profile)
        default: return false
        }
    }
}
