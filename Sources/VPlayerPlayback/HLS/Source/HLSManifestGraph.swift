// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct HLSManifestGraph: Sendable, CustomStringConvertible, CustomReflectable {
    public static let maximumPlaylistBytes = 1_024 * 1_024
    public static let maximumGraphBytes = 4 * 1_024 * 1_024
    public static let maximumDocuments = 128
    public static let maximumReferences = 1_024
    public static let maximumDepth = 4
    public enum ReferenceKind: Sendable, Hashable { case variant, rendition, iframe, segment, initialization, key }
    public struct Reference: Sendable, CustomStringConvertible, CustomReflectable {
        public let kind: ReferenceKind
        public let url: URL
        public let originalURI: String
        public let byteRange: Range<Int>
        public var description: String { "HLSReference(transport=redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["transport": "redacted"]) }
    }
    public struct Variant: Sendable, CustomStringConvertible, CustomReflectable {
        public let url: URL
        public let attributes: [String: String]
        public var description: String { "HLSVariant(transport=redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["transport": "redacted"]) }
    }
    public struct Rendition: Sendable, CustomStringConvertible, CustomReflectable {
        public let url: URL?
        public let attributes: [String: String]
        public var description: String { "HLSRendition(transport=redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["transport": "redacted"]) }
    }
    public struct Resource: Sendable, Hashable, CustomStringConvertible, CustomReflectable {
        public let url: URL
        public let range: HLSByteRange?
        public init(url: URL, range: HLSByteRange?) { self.url = url; self.range = range }
        public var description: String { "HLSResource(transport=redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["transport": "redacted"]) }
    }
    public enum Encryption: Sendable, Hashable, CustomStringConvertible, CustomReflectable {
        case none
        case aes128(keyURL: URL, iv: Data)
        public var description: String { "HLSEncryption(redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["encryption": "redacted"]) }
    }
    public struct Segment: Sendable, CustomStringConvertible, CustomReflectable {
        public let resource: Resource
        public let initialization: Resource?
        public let discontinuity: Int
        public let mediaSequence: UInt64
        public let encryption: Encryption
        public let initializationEncryption: Encryption
        public var range: HLSByteRange? { resource.range }
        public var description: String { "HLSSegment(transport=redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["transport": "redacted"]) }
    }
    public struct Document: Sendable, CustomStringConvertible, CustomReflectable {
        public enum Kind: Sendable, Equatable { case master, media }
        public let responseURL: URL
        public let rawData: Data
        public let kind: Kind
        public let variants: [Variant]
        public let iframeVariants: [Variant]
        public let renditions: [Rendition]
        public let references: [Reference]
        public let segments: [Segment]
        public let unsupportedFeatures: Set<String>
        public var playlistURLs: [URL] { references.filter { [.variant, .rendition, .iframe].contains($0.kind) }.map(\.url) }
        public var description: String { "HLSDocument(redacted, bytes=\(rawData.count))" }
        public var customMirror: Mirror { Mirror(self, children: ["bytes": rawData.count]) }
    }
    public let rootURL: URL
    public let documents: [URL: Document]
    public let aliases: [URL: URL]
    public var unsupportedFeatures: Set<String> { documents.values.reduce(into: Set<String>()) { $0.formUnion($1.unsupportedFeatures) } }
    public var description: String { "HLSManifestGraph(redacted, documents=\(documents.count))" }
    public var customMirror: Mirror { Mirror(self, children: ["documentCount": documents.count]) }
    public init(rootURL: URL, documents: [URL: Document], aliases: [URL: URL]) { self.rootURL = rootURL; self.documents = documents; self.aliases = aliases }
    public func document(for url: URL) -> Document? { documents[aliases[url] ?? url] }
    public var orderedDocuments: [Document] {
        var result: [Document] = []
        var visited: Set<URL> = []
        func visit(_ url: URL) {
            guard let document = document(for: url), visited.insert(document.responseURL).inserted else { return }
            result.append(document)
            for child in document.playlistURLs { visit(child) }
        }
        visit(rootURL); return result
    }
}

public extension HLSManifestGraph {
    static func parse(data: Data, responseURL: URL) throws -> Self {
        let document = try SourceManifestParser(data: data, url: responseURL).parse()
        return Self(rootURL: responseURL, documents: [responseURL: document], aliases: [responseURL: responseURL])
    }
}

private struct SourceManifestParser {
    typealias Graph = HLSManifestGraph
    let data: Data
    let url: URL
    private struct Attribute { let value: String; let span: Range<Int> }
    func parse() throws -> Graph.Document {
        _ = try PlaybackSourceOrigin(url)
        guard data.count <= Graph.maximumPlaylistBytes else { throw HLSSourceError.byteLimit }
        guard data.starts(with: Data("#EXTM3U".utf8)), String(data: data, encoding: .utf8) != nil else { throw HLSSourceError.malformedManifest }
        var variants: [Graph.Variant] = [], iframeVariants: [Graph.Variant] = [], renditions: [Graph.Rendition] = [], references: [Graph.Reference] = [], segments: [Graph.Segment] = []
        var unsupported: Set<String> = []
        var pendingVariant: [String: String]?
        var pendingRange: String?
        var previousSegment: Graph.Resource?, initialization: Graph.Resource?
        var initializationEncryption: Graph.Encryption = .none
        var activeKey: (url: URL, iv: Data?)?
        var sequence: UInt64 = 0
        var discontinuity = 0
        var sawSequence = false, sawDiscontinuitySequence = false, master = false, media = false
        var start = 0, lineCount = 0
        while start < data.count {
            lineCount += 1
            guard lineCount <= 16_384 else { throw HLSSourceError.graphLimit }
            var end = start
            while end < data.count && data[end] != 10 { end += 1 }
            let contentEnd = end > start && data[end-1] == 13 ? end-1 : end
            guard let line = String(data: data[start..<contentEnd], encoding: .utf8) else { throw HLSSourceError.malformedManifest }
            defer { start = end + 1 }
            if lineCount == 1 { guard line == "#EXTM3U" else { throw HLSSourceError.malformedManifest }; continue }
            if line.isEmpty { continue }
            if !line.hasPrefix("#") {
                let reference = try reference(line, span: start..<contentEnd, kind: pendingVariant == nil ? .segment : .variant)
                references.append(reference)
                if let attributes = pendingVariant {
                    master = true; variants.append(.init(url: reference.url, attributes: attributes)); pendingVariant = nil
                } else {
                    media = true
                    let range = try byteRange(pendingRange, resource: reference.url, previous: previousSegment)
                    let resource = Graph.Resource(url: reference.url, range: range)
                    let next = sequence.addingReportingOverflow(UInt64(segments.count))
                    guard !next.overflow else { throw HLSSourceError.malformedManifest }
                    let encryption: Graph.Encryption = activeKey.map { .aes128(keyURL: $0.url, iv: $0.iv ?? sequenceIV(next.partialValue)) } ?? .none
                    if range != nil && activeKey != nil { unsupported.insert("encrypted-byte-range") }
                    segments.append(.init(resource: resource, initialization: initialization, discontinuity: discontinuity,
                        mediaSequence: next.partialValue, encryption: encryption, initializationEncryption: initializationEncryption))
                    previousSegment = resource; pendingRange = nil
                }
                if line.contains("{$") { unsupported.insert("variable-substitution") }
            } else if line.hasPrefix("#EXT-X-") {
                let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let tag = String(pieces[0]), payload = pieces.count == 2 ? String(pieces[1]) : ""
                let offset = start + tag.utf8.count + 1
                switch tag {
                case "#EXT-X-STREAM-INF":
                    guard pendingVariant == nil else { throw HLSSourceError.malformedManifest }
                    let fields = try attributes(payload, offset: offset)
                    guard let bandwidth = fields["BANDWIDTH"], let value = UInt64(bandwidth.value), value > 0 else { throw HLSSourceError.malformedManifest }
                    pendingVariant = fields.mapValues(\.value); master = true
                case "#EXT-X-MEDIA", "#EXT-X-I-FRAME-STREAM-INF":
                    let fields = try attributes(payload, offset: offset)
                    if tag == "#EXT-X-MEDIA" {
                        guard fields["TYPE"] != nil, fields["GROUP-ID"] != nil, fields["NAME"] != nil else { throw HLSSourceError.malformedManifest }
                        let ref = try fields["URI"].map { try reference($0.value, span: $0.span, kind: .rendition) }
                        if let ref { references.append(ref) }
                        renditions.append(.init(url: ref?.url, attributes: fields.mapValues(\.value)))
                    } else {
                        guard let uri = fields["URI"] else { throw HLSSourceError.malformedManifest }
                        let ref = try reference(uri.value, span: uri.span, kind: .iframe)
                        references.append(ref)
                        iframeVariants.append(.init(url: ref.url, attributes: fields.mapValues(\.value)))
                    }
                    master = true
                case "#EXT-X-MAP":
                    let fields = try attributes(payload, offset: offset)
                    guard let uri = fields["URI"] else { throw HLSSourceError.malformedManifest }
                    let ref = try reference(uri.value, span: uri.span, kind: .initialization)
                    references.append(ref)
                    initialization = .init(url: ref.url, range: try byteRange(fields["BYTERANGE"]?.value, resource: ref.url, previous: initialization))
                    initializationEncryption = .none
                    if let activeKey {
                        if let iv = activeKey.iv { initializationEncryption = .aes128(keyURL: activeKey.url, iv: iv) }
                        else { unsupported.insert("encrypted-map-without-explicit-iv") }
                        if initialization?.range != nil { unsupported.insert("encrypted-byte-range") }
                    }
                    media = true
                case "#EXT-X-KEY", "#EXT-X-SESSION-KEY":
                    let fields = try attributes(payload, offset: offset)
                    guard let method = fields["METHOD"]?.value else { throw HLSSourceError.malformedManifest }
                    if method == "NONE" {
                        guard fields.count == 1, tag == "#EXT-X-KEY" else { throw HLSSourceError.malformedManifest }
                        activeKey = nil
                    } else {
                        guard let uri = fields["URI"] else { throw HLSSourceError.malformedManifest }
                        let supported = method == "AES-128" && (fields["KEYFORMAT"]?.value ?? "identity") == "identity" && (fields["KEYFORMATVERSIONS"]?.value ?? "1") == "1"
                        references.append(try reference(uri.value, span: uri.span, kind: .key, allowUnsupportedScheme: !supported))
                        if supported {
                            let key = try reference(uri.value, span: uri.span, kind: .key).url
                            let iv = try fields["IV"].map { try parseIV($0.value) }
                            if tag == "#EXT-X-KEY" { activeKey = (key, iv) }
                        } else { unsupported.insert("unsupported-encryption"); activeKey = nil }
                    }
                case "#EXT-X-BYTERANGE":
                    guard pendingRange == nil else { throw HLSSourceError.malformedManifest }
                    pendingRange = payload
                case "#EXT-X-MEDIA-SEQUENCE":
                    guard !sawSequence, segments.isEmpty, let value = UInt64(payload) else { throw HLSSourceError.malformedManifest }
                    sequence = value; sawSequence = true
                case "#EXT-X-DISCONTINUITY-SEQUENCE":
                    guard !sawDiscontinuitySequence, segments.isEmpty, let value = Int(payload), value >= 0 else { throw HLSSourceError.malformedManifest }
                    discontinuity = value; sawDiscontinuitySequence = true
                case "#EXT-X-DISCONTINUITY":
                    guard discontinuity < Int.max else { throw HLSSourceError.malformedManifest }
                    discontinuity += 1
                case "#EXT-X-DEFINE", "#EXT-X-PART", "#EXT-X-PART-INF", "#EXT-X-PRELOAD-HINT", "#EXT-X-SERVER-CONTROL", "#EXT-X-SKIP", "#EXT-X-RENDITION-REPORT", "#EXT-X-CONTENT-STEERING":
                    unsupported.insert("unsupported-extension")
                default:
                    if payload.contains("URI=") || payload.contains("URL=") || payload.contains("{$") { unsupported.insert("unmanaged-uri-extension") }
                }
            }
            guard references.count <= Graph.maximumReferences else { throw HLSSourceError.graphLimit }
        }
        guard pendingVariant == nil, pendingRange == nil, master != media else { throw HLSSourceError.malformedManifest }
        return Graph.Document(responseURL: url, rawData: data, kind: master ? .master : .media, variants: variants,
            iframeVariants: iframeVariants, renditions: renditions, references: references, segments: segments, unsupportedFeatures: unsupported)
    }
    private func reference(_ text: String, span: Range<Int>, kind: Graph.ReferenceKind, allowUnsupportedScheme: Bool = false) throws -> Graph.Reference {
        guard !text.isEmpty, text.utf8.count <= 8_192, !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let resolved = URL(string: text, relativeTo: url)?.absoluteURL else { throw HLSSourceError.invalidURL }
        if !allowUnsupportedScheme { _ = try PlaybackSourceOrigin(resolved) }
        return .init(kind: kind, url: resolved, originalURI: text, byteRange: span)
    }
    private func attributes(_ text: String, offset: Int) throws -> [String: Attribute] {
        let bytes = Array(text.utf8)
        var result: [String: Attribute] = [:], index = 0
        while index < bytes.count {
            let keyStart = index
            while index < bytes.count, bytes[index] != 61 { index += 1 }
            guard index > keyStart, index < bytes.count else { throw HLSSourceError.malformedManifest }
            let keyBytes = bytes[keyStart..<index]
            guard keyBytes.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  let key = String(bytes: keyBytes, encoding: .utf8), result[key] == nil else { throw HLSSourceError.malformedManifest }
            index += 1
            let quoted = index < bytes.count && bytes[index] == 34
            if quoted { index += 1 }
            let start = index
            while index < bytes.count && bytes[index] != (quoted ? 34 : 44) { index += 1 }
            let end = index
            guard let value = String(bytes: bytes[start..<end], encoding: .utf8), !value.contains("\r"), !value.contains("\n") else { throw HLSSourceError.malformedManifest }
            if quoted { guard index < bytes.count else { throw HLSSourceError.malformedManifest }; index += 1 }
            result[key] = Attribute(value: value, span: (offset+start)..<(offset+end))
            guard result.count <= 64 else { throw HLSSourceError.graphLimit }
            if index < bytes.count {
                guard bytes[index] == 44, index+1 < bytes.count else { throw HLSSourceError.malformedManifest }
                index += 1
            }
        }
        return result
    }
    private func byteRange(_ text: String?, resource: URL, previous: Graph.Resource?) throws -> HLSByteRange? {
        guard let text else { return nil }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let length = Int64(parts[0]), length > 0 else { throw HLSSourceError.malformedManifest }
        let offset: Int64
        if parts.count == 2 {
            guard let explicit = Int64(parts[1]), explicit >= 0 else { throw HLSSourceError.malformedManifest }
            offset = explicit
        } else {
            guard previous?.url == resource, let range = previous?.range else { throw HLSSourceError.malformedManifest }
            let end = range.offset.addingReportingOverflow(range.length)
            guard !end.overflow else { throw HLSSourceError.malformedManifest }
            offset = end.partialValue
        }
        guard !offset.addingReportingOverflow(length).overflow else { throw HLSSourceError.malformedManifest }
        return .init(offset: offset, length: length)
    }
    private func sequenceIV(_ value: UInt64) -> Data {
        var iv = Data(repeating: 0, count: 16)
        for i in 0..<8 { iv[15-i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
        return iv
    }
    private func parseIV(_ text: String) throws -> Data {
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { throw HLSSourceError.malformedManifest }
        let digits = Array(text.dropFirst(2).utf8)
        guard !digits.isEmpty, digits.count <= 32 else { throw HLSSourceError.malformedManifest }
        var result = Data(repeating: 0, count: 16)
        for (index, byte) in digits.reversed().enumerated() {
            let nibble: UInt8
            switch byte { case 48...57: nibble = byte-48; case 65...70: nibble = byte-55; case 97...102: nibble = byte-87; default: throw HLSSourceError.malformedManifest }
            result[15-index/2] |= nibble << (index%2 == 0 ? 0 : 4)
        }
        return result
    }
}
