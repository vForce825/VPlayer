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
