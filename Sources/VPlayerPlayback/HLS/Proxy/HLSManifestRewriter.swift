// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum HLSManifestRewriter {
    static func masterTransportSkeleton(_ document: HLSManifestGraph.Document) throws -> Data {
        guard document.kind == .master else { throw HLSSourceError.unsupportedMedia }
        return try transportSkeleton(document, playlists: true)
    }
    static func protectionContracts(_ document: HLSManifestGraph.Document) throws -> Set<String> {
        let data = try transportSkeleton(document, playlists: false)
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("#EXT-X-KEY:") || $0.hasPrefix("#EXT-X-SESSION-KEY:") }.map(String.init))
    }
    /// Compare declared roles/attributes exactly while allowing only parser-proven
    /// playlist/key locators and validated AES IV values to renew. Never serve this.
    private static func transportSkeleton(_ document: HLSManifestGraph.Document, playlists: Bool) throws -> Data {
        guard document.unsupportedFeatures.isEmpty else { throw HLSSourceError.unsupportedMedia }
        var result = Data(), cursor = 0
        for reference in document.references where reference.kind == .key ||
            (playlists && [.variant, .rendition, .iframe].contains(reference.kind)) {
            guard reference.byteRange.lowerBound >= cursor, reference.byteRange.upperBound <= document.rawData.count else {
                throw HLSSourceError.malformedManifest
            }
            result.append(document.rawData[cursor..<reference.byteRange.lowerBound])
            result.append(contentsOf: (reference.kind == .key ? "<owned-aes-key>" : "<owned-playlist-role>").utf8)
            cursor = reference.byteRange.upperBound
        }
        result.append(document.rawData[cursor...])
        let lines = String(decoding: result, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return Data(try lines.map { line -> String in
            guard line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:"),
                  let colon = line.firstIndex(of: ":") else { return String(line) }
            let bytes = Array(line[line.index(after: colon)...].utf8)
            var fields: [String] = [], start = 0, quoted = false
            for index in bytes.indices {
                if bytes[index] == 34 { quoted.toggle() }
                if bytes[index] == 44 && !quoted {
                    fields.append(String(decoding: bytes[start..<index], as: UTF8.self)); start = index + 1
                }
            }
            guard !quoted else { throw HLSSourceError.malformedManifest }
            fields.append(String(decoding: bytes[start...], as: UTF8.self))
            fields = fields.map { $0.hasPrefix("IV=") ? "IV=<owned-aes-iv>" + ($0.hasSuffix("\r") ? "\r" : "") : $0 }
            return String(line[...colon]) + fields.joined(separator: ",")
        }.joined(separator: "\n").utf8)
    }

    static func rewrite(_ document: HLSManifestGraph.Document, registry: HLSProxyResourceRegistry,
                        mediaType: HLSProxyMediaType? = nil, childRoles: [URL: HLSProxyManifestRole] = [:],
                        protectedBodies: [URL: HLSProxyProtectedBody]? = nil) throws -> Data {
        guard document.unsupportedFeatures.isEmpty, document.rawData.count <= HLSManifestGraph.maximumPlaylistBytes else {
            throw HLSSourceError.unsupportedMedia
        }
        var output = Data(), cursor = 0
        for reference in document.references.sorted(by: { $0.byteRange.lowerBound < $1.byteRange.lowerBound }) {
            guard reference.byteRange.lowerBound >= cursor, reference.byteRange.upperBound <= document.rawData.count else {
                throw HLSSourceError.malformedManifest
            }
            let body: HLSProxyProtectedBody?
            if reference.kind == .key || reference.kind == .initialization {
                body = protectedBodies?[reference.url]
                if protectedBodies != nil && body == nil { throw HLSSourceError.incompleteEvidence }
            } else { body = nil }
            let type = HLSProxyMediaType.reference(reference.kind, url: reference.url, provenMedia: mediaType)
            let path = try registry.register(url: reference.url, kind: reference.kind, mediaType: type,
                manifestRole: childRoles[reference.url], protectedBody: body)
            let growth = reference.byteRange.lowerBound - cursor + path.utf8.count
            guard growth <= HLSManifestGraph.maximumPlaylistBytes - output.count else { throw HLSSourceError.byteLimit }
            output.append(document.rawData[cursor..<reference.byteRange.lowerBound]); output.append(contentsOf: path.utf8)
            cursor = reference.byteRange.upperBound
        }
        guard document.rawData.count - cursor <= HLSManifestGraph.maximumPlaylistBytes - output.count else { throw HLSSourceError.byteLimit }
        output.append(document.rawData[cursor...])
        return output
    }
}

enum HLSProxyHTTP {
    struct ContentRange { let first: Int64; let last: Int64; let total: Int64 }
    static func authorize(_ request: LoopbackHTTPRequest, port: UInt16, prefix: String) throws {
        guard request.method != .unsupported, request.values(forHeader: "Host") == ["127.0.0.1:\(port)"],
              request.target.hasPrefix(prefix) else { throw HLSSourceError.invalidURL }
        let parts = request.target.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
              UInt64(parts[0]) != nil, HLSProxyMediaType(rawValue: String(parts[1])) != nil,
              request.values(forHeader: "Range").count <= 1,
              request.values(forHeader: "If-Range").isEmpty, request.values(forHeader: "If-None-Match").isEmpty,
              request.values(forHeader: "If-Modified-Since").isEmpty else { throw HLSSourceError.invalidURL }
    }
    static func validateEncoding(_ value: String?) throws {
        guard value == nil || value?.lowercased() == "identity" else { throw HLSSourceError.unsupportedMedia }
    }
    static func contentRange(_ value: String) throws -> ContentRange {
        guard value.hasPrefix("bytes ") else { throw HLSSourceError.network }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw HLSSourceError.network }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = decimal(bounds[0]), let last = decimal(bounds[1]),
              let total = decimal(parts[1]), first <= last, last < total else { throw HLSSourceError.network }
        return .init(first: first, last: last, total: total)
    }
    static func validatedRange(_ value: String?) throws -> String? {
        guard let value else { return nil }
        _ = try HTTPRange.parse(value, resourceLength: Int.max)
        return value.contains(",") ? nil : value
    }
    private static func decimal(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
    }
}
