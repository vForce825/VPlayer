// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum HLSWebVTTInspector {
    static func accepts(_ bytes: Data) -> Bool {
        guard bytes.count <= HLSCompatibilityProbe.maximumBytes, let text = String(data: bytes, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, first == "WEBVTT" || first.hasPrefix("WEBVTT ") else { return false }
        for line in lines.dropFirst() {
            if line.hasPrefix("X-TIMESTAMP-MAP=") {
                let fields = line.dropFirst("X-TIMESTAMP-MAP=".count).split(separator: ",")
                guard fields.count == 2, let local = fields.first(where: { $0.hasPrefix("LOCAL:") }),
                      let media = fields.first(where: { $0.hasPrefix("MPEGTS:") }),
                      timestamp(String(local.dropFirst(6))) != nil, let ticks = UInt64(media.dropFirst(7)), ticks < (1 << 33) else { return false }
            }
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                guard parts.count == 2, let start = timestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                      let endText = parts[1].split(whereSeparator: \.isWhitespace).first,
                      let end = timestamp(String(endText)), end > start else { return false }
            }
        }
        // RFC 8216 section 3.5 permits a segment with no cues when subtitles
        // are absent during its interval. The header and any timing/map fields
        // still need to pass the same bounded inspection above.
        return true
    }
    private static func timestamp(_ text: String) -> UInt64? {
        let sections = text.split(separator: ":", omittingEmptySubsequences: false)
        guard sections.count == 2 || sections.count == 3 else { return nil }
        let final = sections.last!.split(separator: ".", omittingEmptySubsequences: false)
        guard final.count == 2, final[0].count == 2, final[1].count == 3, let seconds = UInt64(final[0]), seconds < 60,
              let millis = UInt64(final[1]), millis < 1000, sections[sections.count-2].count == 2,
              let minutes = UInt64(sections[sections.count-2]), minutes < 60 else { return nil }
        let hours: UInt64
        if sections.count == 3 { guard sections[0].count <= 6, let value = UInt64(sections[0]) else { return nil }; hours = value }
        else { hours = 0 }
        return ((hours*60+minutes)*60+seconds)*1000+millis
    }
}
