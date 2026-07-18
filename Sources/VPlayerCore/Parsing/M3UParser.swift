// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum M3UParserError: Error, Equatable, Sendable {
    case missingHeader
    case noChannels
}

public struct M3UParser: Sendable {
    private let decoder = PlaylistTextDecoder()

    public init() {}

    public func parse(data: Data, sourceURL: URL, profileID: UUID) throws -> [Channel] {
        let text = try decoder.decode(data)
        let lines = text.components(separatedBy: .newlines)
        guard lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("#EXTM3U") == true else { throw M3UParserError.missingHeader }

        var pending: (name: String, attributes: [String: String])?
        var channels: [Channel] = []
        var seen = Set<String>()

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTINF:") {
                pending = parseEXTINF(line)
                continue
            }
            guard !line.hasPrefix("#"), let metadata = pending,
                  let streamURL = URL(string: line, relativeTo: sourceURL)?.absoluteURL else { continue }
            pending = nil
            let identity = ChannelIdentity.make(profileID: profileID, streamURL: streamURL)
            guard seen.insert(identity).inserted else { continue }
            let attributes = metadata.attributes
            channels.append(Channel(
                sourceProfileID: profileID,
                displayName: metadata.name,
                streamURL: streamURL,
                tvgID: nonEmpty(attributes["tvg-id"]),
                tvgName: nonEmpty(attributes["tvg-name"]),
                logoURL: nonEmpty(attributes["tvg-logo"]).flatMap(URL.init(string:)),
                groupTitle: nonEmpty(attributes["group-title"]),
                attributes: attributes,
                order: channels.count
            ))
        }
        guard !channels.isEmpty else { throw M3UParserError.noChannels }
        return channels
    }

    private func parseEXTINF(_ line: String) -> (name: String, attributes: [String: String]) {
        let payload = String(line.dropFirst("#EXTINF:".count))
        let comma = firstUnquotedComma(in: payload) ?? payload.endIndex
        let metadata = payload[..<comma]
        let nameStart = comma == payload.endIndex ? comma : payload.index(after: comma)
        let name = payload[nameStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSpace = metadata.firstIndex(where: { $0.isWhitespace }) ?? metadata.endIndex
        return (name.isEmpty ? "Unnamed channel" : name, scanAttributes(String(metadata[firstSpace...])))
    }

    private func firstUnquotedComma(in value: String) -> String.Index? {
        var quoted = false
        for index in value.indices {
            if value[index] == "\"" { quoted.toggle() }
            if value[index] == "," && !quoted { return index }
        }
        return nil
    }

    private func scanAttributes(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = value.startIndex
        while index < value.endIndex {
            while index < value.endIndex && value[index].isWhitespace { index = value.index(after: index) }
            let keyStart = index
            while index < value.endIndex && value[index] != "=" && !value[index].isWhitespace {
                index = value.index(after: index)
            }
            guard keyStart < index else { break }
            let key = String(value[keyStart..<index]).lowercased()
            while index < value.endIndex && value[index].isWhitespace { index = value.index(after: index) }
            guard index < value.endIndex, value[index] == "=" else {
                while index < value.endIndex && !value[index].isWhitespace { index = value.index(after: index) }
                continue
            }
            index = value.index(after: index)
            while index < value.endIndex && value[index].isWhitespace { index = value.index(after: index) }
            if index < value.endIndex && value[index] == "\"" {
                index = value.index(after: index)
                let start = index
                while index < value.endIndex && value[index] != "\"" { index = value.index(after: index) }
                result[key] = String(value[start..<index])
                if index < value.endIndex { index = value.index(after: index) }
            } else {
                let start = index
                while index < value.endIndex && !value[index].isWhitespace { index = value.index(after: index) }
                result[key] = String(value[start..<index])
            }
        }
        return result
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
