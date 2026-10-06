// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public protocol HLSCompatibilityProbing: Sendable {
    func inspect(_ source: ResolvedPlaybackSource) async throws -> HLSCompatibilityFacts
}

/// The production prepare owner has already reserved factsRetention. Passing its
/// reference keeps that same reservation alive for every copied receipt alias.
protocol HLSPaidCompatibilityProbing: HLSCompatibilityProbing {
    func inspect(_ source: ResolvedPlaybackSource, retainingFacts charge: HLSApplicationLifetimeCharge) async throws -> HLSCompatibilityFacts
}

/// Plaintext identity evidence only. It neither creates format facts nor renews
/// playback authority. No initializer, record mutation or test minting seam is public.
public struct HLSInitializationReceipts: Sendable, CustomStringConvertible, CustomReflectable {
    public static let maximumCount = 128
    public static let empty = Self(owner: nil, generation: 0, charge: nil, records: [])
    private let owner: PlaybackSourceOwner?
    private let generation: UInt64
    private let charge: HLSApplicationLifetimeCharge?
    private let records: [InitializationReceipt]
    public var count: Int { records.count }
    public var description: String { "HLSInitializationReceipts(redacted, count=\(count))" }
    public var customMirror: Mirror { Mirror(self, children: ["count": count]) }

    fileprivate init(owner: PlaybackSourceOwner?, generation: UInt64, charge: HLSApplicationLifetimeCharge?, records: [InitializationReceipt]) {
        self.owner = owner; self.generation = generation; self.charge = charge; self.records = records
    }

    public func plaintextByteCount(source: ResolvedPlaybackSource, originalMediaURL: URL,
                                   originalResource: HLSManifestGraph.Resource, originalEncryption: HLSManifestGraph.Encryption) -> Int? {
        guard let owner, charge != nil else { return nil }
        return source.withCurrentResolution(owner: owner, generation: generation) {
            receipt(source: source, mediaURL: originalMediaURL, resource: originalResource, encryption: originalEncryption)?.byteCount
        } ?? nil
    }

    public func matches(plaintext: Data, source: ResolvedPlaybackSource, originalMediaURL: URL,
                        originalResource: HLSManifestGraph.Resource, originalEncryption: HLSManifestGraph.Encryption,
                        replacementRange: HLSByteRange?, replacementEncryption: HLSManifestGraph.Encryption) -> Bool {
        guard let owner, charge != nil, plaintext.count <= HLSCompatibilityProbe.maximumBytes else { return false }
        return source.withCurrentResolution(owner: owner, generation: generation) {
            guard let record = receipt(source: source, mediaURL: originalMediaURL, resource: originalResource, encryption: originalEncryption),
                  record.byteCount == plaintext.count, record.range == replacementRange else { return false }
            switch (record.encrypted, replacementEncryption) {
            case (false, .none): break
            case let (true, .aes128(_, iv)): guard iv.count == 16, replacementRange == nil else { return false }
            default: return false
            }
            return SHA256.hash(data: plaintext) == record.plaintextDigest
        } == true
    }

    private func receipt(source: ResolvedPlaybackSource, mediaURL: URL, resource: HLSManifestGraph.Resource,
                         encryption: HLSManifestGraph.Encryption) -> InitializationReceipt? {
        guard let binding = InitializationReceipt.binding(source: source, mediaURL: mediaURL, resource: resource, encryption: encryption) else { return nil }
        return records.first { $0.bindingDigest == binding }
    }
}

fileprivate struct InitializationReceipt: Sendable {
    let bindingDigest: SHA256.Digest
    let plaintextDigest: SHA256.Digest
    let byteCount: Int
    let range: HLSByteRange?
    let encrypted: Bool

    /// Length-framed fields bind the original source graph role and declaration.
    /// Only fixed-size digests/scalars survive; neither URLs nor MAP bodies do.
    static func binding(source: ResolvedPlaybackSource, mediaURL: URL, resource: HLSManifestGraph.Resource,
                        encryption: HLSManifestGraph.Encryption) -> SHA256.Digest? {
        guard case let .hls(graph) = source.topology, graph.documents.count <= HLSManifestGraph.maximumDocuments,
              let document = graph.document(for: mediaURL), document.kind == .media,
              let first = document.segments.first, first.initialization == resource,
              first.initializationEncryption == encryption else { return nil }
        var graphBytes = 0
        for item in graph.documents.values {
            guard item.rawData.count <= HLSManifestGraph.maximumPlaylistBytes,
                  item.rawData.count <= HLSManifestGraph.maximumGraphBytes - graphBytes else { return nil }
            graphBytes += item.rawData.count
        }
        var hasher = SHA256()
        func append(_ data: Data) {
            var size = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        append(Data("HLS inspected initialization v1".utf8))
        append(Data(graph.rootURL.absoluteString.utf8))
        // Preserve all original parent declarations, including role/group/codec
        // attributes. Renewed graph-role validation still belongs to the proxy.
        for parent in graph.orderedDocuments where parent.kind == .master {
            append(Data(parent.responseURL.absoluteString.utf8)); append(parent.rawData)
        }
        append(Data(document.responseURL.absoluteString.utf8)); append(document.rawData)
        append(Data(resource.url.absoluteString.utf8))
        let rangeDeclaration = resource.range.map { "\($0.offset):\($0.length)" } ?? "none"
        append(Data(rangeDeclaration.utf8))
        switch encryption {
        case .none: append(Data("none".utf8))
        case let .aes128(keyURL, iv): append(Data("AES-128:identity:1".utf8)); append(Data(keyURL.absoluteString.utf8)); append(iv)
        }
        return hasher.finalize()
    }
}

public protocol HLSContainerInspecting: Sendable {
    func inspect(data: Data, url: URL, deadline: UInt64) async throws -> HLSMediaFacts
    func inspect(data: Data, url: URL, deadline: UInt64, completeness: HLSMediaCompleteness) async throws -> HLSMediaFacts
}

public extension HLSContainerInspecting {
    func inspect(data: Data, url: URL, deadline: UInt64, completeness: HLSMediaCompleteness) async throws -> HLSMediaFacts {
        guard completeness == .complete else { throw HLSSourceError.incompleteEvidence }
        return try await inspect(data: data, url: url, deadline: deadline)
    }
}

/// Cache contents are admitted before use, bound to the complete source attempt,
/// and keyed by the exact signed URL and byte range. No cross-request token reuse.
public struct HLSProbeByteCache: Sendable, CustomStringConvertible, CustomReflectable {
    public var description: String { "HLSProbeByteCache(redacted, resources=\(resources.count))" }
    public var customMirror: Mirror { Mirror(self, children: ["resources": resources.count]) }
    public let owner: PlaybackSourceOwner
    public let generation: UInt64
    public let resources: [HLSManifestGraph.Resource: Data]
    public init(owner: PlaybackSourceOwner, generation: UInt64, resources: [HLSManifestGraph.Resource: Data]) throws {
        var total = 0
        guard resources.count <= HLSManifestGraph.maximumReferences else { throw HLSSourceError.byteLimit }
        for value in resources.values {
            guard value.count <= HLSCompatibilityProbe.maximumBytes - total else { throw HLSSourceError.byteLimit }
            total += value.count
        }
        self.owner = owner; self.generation = generation; self.resources = resources
    }
}

public struct HLSCompatibilityProbe: HLSPaidCompatibilityProbing {
    public static let maximumBytes = 8 * 1_024 * 1_024
    private let transport: any HLSResourceTransport
    private let inspector: any HLSContainerInspecting
    private let cache: HLSProbeByteCache?

    public init(transport: any HLSResourceTransport = URLSessionHLSResourceTransport(),
                inspector: any HLSContainerInspecting = FFmpegHLSContainerInspector(), cache: HLSProbeByteCache? = nil) {
        self.transport = transport; self.inspector = inspector; self.cache = cache
    }

    public func inspect(_ source: ResolvedPlaybackSource) async throws -> HLSCompatibilityFacts {
        try await inspect(source, factsCharge: nil)
    }

    func inspect(_ source: ResolvedPlaybackSource, retainingFacts charge: HLSApplicationLifetimeCharge) async throws -> HLSCompatibilityFacts {
        guard charge.reservedBytes >= HLSPreflightMemoryLimits.factsRetention else { throw HLSSourceError.capacity }
        return try await inspect(source, factsCharge: charge)
    }

    private func inspect(_ source: ResolvedPlaybackSource, factsCharge: HLSApplicationLifetimeCharge?) async throws -> HLSCompatibilityFacts {
        try Task.checkCancellation()
        guard let owner = source.context.owner else { throw HLSSourceError.unboundOwner }
        if let cache { guard cache.owner == owner, cache.generation == source.generation else { throw HLSSourceError.staleResolution } }
        let deadline = HLSMonotonicClock.deadline(seconds: 10)
        var bytes = 0
        var media: [HLSMediaFacts] = []
        var retainedConfigurationBytes = 0
        var loaded: [HLSManifestGraph.Resource: Data] = [:]
        // At most 128 fixed digest/scalar records (<64 KiB of conservative retained
        // metadata allowance) share the already reserved 4 MiB facts lifetime.
        var initializationRecords: [InitializationReceipt] = []
        switch source.topology {
        case let .media(data):
            guard !data.isEmpty, data.count <= Self.maximumBytes else { throw HLSSourceError.byteLimit }
            bytes = data.count
            let fact = try await inspector.inspect(data: data, url: source.responseURL, deadline: deadline, completeness: source.mediaCompleteness)
            try admitFacts(fact, configurationBytes: &retainedConfigurationBytes)
            media = [fact]
        case let .hls(graph):
            guard graph.unsupportedFeatures.isEmpty else {
                HLSPreparationDiagnostics.current?.reject(.manifestFeatures)
                throw HLSSourceError.unsupportedMedia
            }
            let documents = graph.orderedDocuments.filter { $0.kind == .media }
            guard !documents.isEmpty else { throw HLSSourceError.incompleteEvidence }
            guard documents.count <= HLSInitializationReceipts.maximumCount else { throw HLSSourceError.graphLimit }
            for document in documents {
                try Task.checkCancellation()
                guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
                guard let segment = document.segments.first else { throw HLSSourceError.incompleteEvidence }
                let sample = try await inspectedResource(segment.resource, encryption: segment.encryption, source: source, deadline: deadline, bytes: &bytes, loaded: &loaded)
                let input: Data
                var initializationIdentity: (SHA256.Digest, Int)?
                if let initialization = segment.initialization {
                    let header = try await inspectedResource(initialization, encryption: segment.initializationEncryption, source: source, deadline: deadline, bytes: &bytes, loaded: &loaded)
                    if factsCharge != nil, inspector is FFmpegHLSContainerInspector {
                        initializationIdentity = (SHA256.hash(data: header), header.count)
                    }
                    guard header.count <= Self.maximumBytes - sample.count else { throw HLSSourceError.byteLimit }
                    try reserve(header.count + sample.count, bytes: &bytes)
                    var combined = Data(capacity: header.count + sample.count)
                    combined.append(header); combined.append(sample)
                    input = combined
                } else { input = sample }
                let fact: HLSMediaFacts
                if HLSWebVTTInspector.accepts(input) {
                    fact = HLSMediaFacts(url: document.responseURL, container: .webVTT, video: nil, audio: [], hasUnsupportedTracks: false)
                } else {
                    fact = try await inspector.inspect(data: input, url: document.responseURL, deadline: deadline)
                }
                try admitFacts(fact, configurationBytes: &retainedConfigurationBytes)
                media.append(fact)
                if let identity = initializationIdentity, let initialization = segment.initialization,
                   fact.container == .fragmentedMP4 || fact.container == .mpegTS,
                   let binding = InitializationReceipt.binding(source: source, mediaURL: document.responseURL,
                        resource: initialization, encryption: segment.initializationEncryption) {
                    initializationRecords.append(InitializationReceipt(bindingDigest: binding, plaintextDigest: identity.0,
                        byteCount: identity.1, range: initialization.range, encrypted: segment.initializationEncryption != .none))
                }
            }
        }
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        let receipts: HLSInitializationReceipts = initializationRecords.isEmpty ? .empty :
            .init(owner: owner, generation: source.generation, charge: factsCharge, records: initializationRecords)
        return HLSCompatibilityFacts(source: source, media: media, complete: true, inspectedBytes: bytes, initializationReceipts: receipts)
    }

    private func admitFacts(_ fact: HLSMediaFacts, configurationBytes: inout Int) throws {
        guard fact.audio.count <= 32 else { throw HLSSourceError.byteLimit }
        for audio in fact.audio {
            guard audio.decoderConfiguration.count <= HLSPreflightMemoryLimits.maximumRetainedAudioConfigurationBytes - configurationBytes else { throw HLSSourceError.byteLimit }
            configurationBytes += audio.decoderConfiguration.count
        }
    }

    private func reserve(_ count: Int, bytes: inout Int) throws {
        guard count >= 0, count <= Self.maximumBytes - bytes else { throw HLSSourceError.byteLimit }
        bytes += count
    }

    private func inspectedResource(_ resource: HLSManifestGraph.Resource, encryption: HLSManifestGraph.Encryption,
                                   source: ResolvedPlaybackSource, deadline: UInt64, bytes: inout Int,
                                   loaded: inout [HLSManifestGraph.Resource: Data]) async throws -> Data {
        let data = try await fetch(resource, source: source, deadline: deadline, bytes: &bytes, loaded: &loaded)
        guard case let .aes128(keyURL, iv) = encryption else { return data }
        guard resource.range == nil else {
            HLSPreparationDiagnostics.current?.reject(.encryptedRange)
            throw HLSSourceError.unsupportedMedia
        }
        let keyResource = HLSManifestGraph.Resource(url: keyURL, range: nil)
        let key = try await fetch(keyResource, source: source, deadline: deadline, bytes: &bytes, loaded: &loaded, resourceLimit: 16)
        guard key.count == 16 else {
            HLSPreparationDiagnostics.current?.reject(.keyLength)
            throw HLSSourceError.unsupportedMedia
        }
        try reserve(data.count + HLSAES128Preflight.workspaceBytes, bytes: &bytes)
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        let plaintext = try HLSAES128Preflight.decrypt(data, key: key, iv: iv)
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        return plaintext
    }

    private func fetch(_ resource: HLSManifestGraph.Resource, source: ResolvedPlaybackSource, deadline: UInt64,
                       bytes: inout Int, loaded: inout [HLSManifestGraph.Resource: Data], resourceLimit: Int = HLSCompatibilityProbe.maximumBytes) async throws -> Data {
        if let value = loaded[resource] {
            guard value.count <= resourceLimit else { throw HLSSourceError.byteLimit }
            return value
        }
        let remaining = Self.maximumBytes - bytes
        guard remaining > 0 else { throw HLSSourceError.byteLimit }
        let value: Data
        if let cached = cache?.resources[resource] { value = cached } else {
            let response = try await transport.fetch(.init(url: resource.url, headers: source.context.headers,
                range: resource.range, maximumBytes: min(remaining, resourceLimit), deadline: deadline))
            guard response.completeness == .complete || (resource.range != nil && response.completeness == .byteRange) else { throw HLSSourceError.incompleteEvidence }
            value = response.data
        }
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        guard !value.isEmpty, value.count <= remaining, value.count <= resourceLimit,
              resource.range == nil || Int64(value.count) == resource.range?.length else { throw HLSSourceError.byteLimit }
        bytes += value.count
        loaded[resource] = value
        return value
    }
}
