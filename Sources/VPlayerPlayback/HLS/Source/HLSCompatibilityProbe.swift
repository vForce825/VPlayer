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
    private static let tsInitialAcquisitionBytes = 1 * 1_024 * 1_024
    private static let maximumConcurrentVariants = 3
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

    private struct VariantProbeOutcome: Sendable {
        let index: Int
        let fact: HLSMediaFacts
        let inspectedBytes: Int
        let initializationReceipt: InitializationReceipt?
    }

    private func inspect(_ source: ResolvedPlaybackSource, factsCharge: HLSApplicationLifetimeCharge?) async throws -> HLSCompatibilityFacts {
        try Task.checkCancellation()
        guard let owner = source.context.owner else { throw HLSSourceError.unboundOwner }
        if let cache { guard cache.owner == owner, cache.generation == source.generation else { throw HLSSourceError.staleResolution } }
        let deadline = HLSMonotonicClock.deadline(seconds: 10)
        var peakInspectedBytes = 0
        var media: [HLSMediaFacts] = []
        var retainedConfigurationBytes = 0
        // At most 128 fixed digest/scalar records (<64 KiB of conservative retained
        // metadata allowance) share the already reserved 4 MiB facts lifetime.
        var initializationRecords: [InitializationReceipt] = []
        switch source.topology {
        case let .media(data):
            guard !data.isEmpty, data.count <= Self.maximumBytes else { throw HLSSourceError.byteLimit }
            peakInspectedBytes = data.count
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

            let outcomes: [VariantProbeOutcome]
            if documents.count == 1 {
                outcomes = [try await inspectVariant(
                    document: documents[0],
                    index: 0,
                    source: source,
                    deadline: deadline,
                    recordInitializationReceipt: factsCharge != nil && inspector is FFmpegHLSContainerInspector
                )]
            } else {
                let recordReceipt = factsCharge != nil && inspector is FFmpegHLSContainerInspector
                outcomes = try await withThrowingTaskGroup(of: VariantProbeOutcome.self) { group in
                    var collected: [VariantProbeOutcome] = []
                    collected.reserveCapacity(documents.count)
                    var nextIndex = 0
                    let initialBatch = min(Self.maximumConcurrentVariants, documents.count)
                    for _ in 0..<initialBatch {
                        let idx = nextIndex
                        let document = documents[idx]
                        nextIndex += 1
                        group.addTask {
                            try await self.inspectVariant(
                                document: document,
                                index: idx,
                                source: source,
                                deadline: deadline,
                                recordInitializationReceipt: recordReceipt
                            )
                        }
                    }
                    while let outcome = try await group.next() {
                        collected.append(outcome)
                        if nextIndex < documents.count {
                            let idx = nextIndex
                            let document = documents[idx]
                            nextIndex += 1
                            group.addTask {
                                try await self.inspectVariant(
                                    document: document,
                                    index: idx,
                                    source: source,
                                    deadline: deadline,
                                    recordInitializationReceipt: recordReceipt
                                )
                            }
                        }
                    }
                    return collected.sorted { $0.index < $1.index }
                }
            }

            for outcome in outcomes {
                try admitFacts(outcome.fact, configurationBytes: &retainedConfigurationBytes)
                media.append(outcome.fact)
                peakInspectedBytes = max(peakInspectedBytes, outcome.inspectedBytes)
                if let receipt = outcome.initializationReceipt {
                    initializationRecords.append(receipt)
                }
            }
        }
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        let receipts: HLSInitializationReceipts = initializationRecords.isEmpty ? .empty :
            .init(owner: owner, generation: source.generation, charge: factsCharge, records: initializationRecords)
        return HLSCompatibilityFacts(source: source, media: media, complete: true, inspectedBytes: peakInspectedBytes, initializationReceipts: receipts)
    }

    private func inspectVariant(
        document: HLSManifestGraph.Document,
        index: Int,
        source: ResolvedPlaybackSource,
        deadline: UInt64,
        recordInitializationReceipt: Bool
    ) async throws -> VariantProbeOutcome {
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        guard let segment = document.segments.first else { throw HLSSourceError.incompleteEvidence }
        // 工作内存与字节限额按变体独立作用域核算，单变体探测完成后即释放分片缓冲。
        var variantBytes = 0
        var loaded: [HLSManifestGraph.Resource: Data] = [:]
        let allowTSPrefix = segment.encryption == .none && segment.resource.range == nil && segment.initialization == nil
        let (sample, sampleCompleteness) = try await inspectedResource(
            segment.resource,
            encryption: segment.encryption,
            source: source,
            deadline: deadline,
            bytes: &variantBytes,
            loaded: &loaded,
            allowTSPrefix: allowTSPrefix
        )
        let input: Data
        let inputCompleteness: HLSMediaCompleteness
        var initializationIdentity: (SHA256.Digest, Int)?
        if let initialization = segment.initialization {
            let (header, _) = try await inspectedResource(
                initialization,
                encryption: segment.initializationEncryption,
                source: source,
                deadline: deadline,
                bytes: &variantBytes,
                loaded: &loaded,
                allowTSPrefix: false
            )
            if recordInitializationReceipt {
                initializationIdentity = (SHA256.hash(data: header), header.count)
            }
            // header 与 sample 已在各自 fetch 时计入 variantBytes，这里只校验合并上限，不再重复扣减。
            guard header.count <= Self.maximumBytes - sample.count else { throw HLSSourceError.byteLimit }
            var combined = Data(capacity: header.count + sample.count)
            combined.append(header)
            combined.append(sample)
            input = combined
            inputCompleteness = .complete
        } else {
            input = sample
            inputCompleteness = sampleCompleteness
        }
        let fact: HLSMediaFacts
        if inputCompleteness == .complete, HLSWebVTTInspector.accepts(input) {
            fact = HLSMediaFacts(url: document.responseURL, container: .webVTT, video: nil, audio: [], hasUnsupportedTracks: false)
        } else {
            fact = try await inspector.inspect(data: input, url: document.responseURL, deadline: deadline, completeness: inputCompleteness)
        }
        var receipt: InitializationReceipt?
        if let identity = initializationIdentity, let initialization = segment.initialization,
           fact.container == .fragmentedMP4 || fact.container == .mpegTS,
           let binding = InitializationReceipt.binding(source: source, mediaURL: document.responseURL,
                resource: initialization, encryption: segment.initializationEncryption) {
            receipt = InitializationReceipt(bindingDigest: binding, plaintextDigest: identity.0,
                byteCount: identity.1, range: initialization.range, encrypted: segment.initializationEncryption != .none)
        }
        return VariantProbeOutcome(index: index, fact: fact, inspectedBytes: variantBytes, initializationReceipt: receipt)
    }

    private func admitFacts(_ fact: HLSMediaFacts, configurationBytes: inout Int) throws {
        guard fact.audio.count <= 32 else { throw HLSSourceError.byteLimit }
        for audio in fact.audio {
            guard audio.decoderConfiguration.count <= HLSPreflightMemoryLimits.maximumRetainedAudioConfigurationBytes - configurationBytes else { throw HLSSourceError.byteLimit }
            configurationBytes += audio.decoderConfiguration.count
        }
    }

    private func inspectedResource(_ resource: HLSManifestGraph.Resource, encryption: HLSManifestGraph.Encryption,
                                   source: ResolvedPlaybackSource, deadline: UInt64, bytes: inout Int,
                                   loaded: inout [HLSManifestGraph.Resource: Data],
                                   allowTSPrefix: Bool) async throws -> (Data, HLSMediaCompleteness) {
        let (data, completeness) = try await fetch(
            resource,
            source: source,
            deadline: deadline,
            bytes: &bytes,
            loaded: &loaded,
            allowTSPrefix: allowTSPrefix
        )
        guard case let .aes128(keyURL, iv) = encryption else { return (data, completeness) }
        guard resource.range == nil else {
            HLSPreparationDiagnostics.current?.reject(.encryptedRange)
            throw HLSSourceError.unsupportedMedia
        }
        let keyResource = HLSManifestGraph.Resource(url: keyURL, range: nil)
        let (key, _) = try await fetch(keyResource, source: source, deadline: deadline, bytes: &bytes, loaded: &loaded, resourceLimit: 16, allowTSPrefix: false)
        guard key.count == 16 else {
            HLSPreparationDiagnostics.current?.reject(.keyLength)
            throw HLSSourceError.unsupportedMedia
        }
        // data 已在 fetch 时计入 bytes；仅检查解密工作区不越界，避免将同一负载重复扣减两次。
        guard data.count <= Self.maximumBytes - HLSAES128Preflight.workspaceBytes else { throw HLSSourceError.byteLimit }
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        let plaintext = try HLSAES128Preflight.decrypt(data, key: key, iv: iv)
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        return (plaintext, .complete)
    }

    private func fetch(_ resource: HLSManifestGraph.Resource, source: ResolvedPlaybackSource, deadline: UInt64,
                       bytes: inout Int, loaded: inout [HLSManifestGraph.Resource: Data],
                       resourceLimit: Int = HLSCompatibilityProbe.maximumBytes,
                       allowTSPrefix: Bool) async throws -> (Data, HLSMediaCompleteness) {
        if let value = loaded[resource] {
            guard value.count <= resourceLimit else { throw HLSSourceError.byteLimit }
            return (value, .complete)
        }
        let remaining = Self.maximumBytes - bytes
        guard remaining > 0 else { throw HLSSourceError.byteLimit }
        let budgetLimit = min(remaining, resourceLimit)
        let value: Data
        let completeness: HLSMediaCompleteness
        if let cached = cache?.resources[resource] {
            value = cached
            completeness = .complete
        } else if allowTSPrefix, resource.range == nil {
            let initialMaximum = min(Self.tsInitialAcquisitionBytes, budgetLimit)
            let continuation = budgetLimit > initialMaximum ? budgetLimit : nil
            let response = try await transport.fetch(.init(
                url: resource.url,
                headers: source.context.headers,
                range: nil,
                maximumBytes: initialMaximum,
                deadline: deadline,
                mode: .classify,
                maximumTSContinuationBytes: continuation
            ))
            if response.completeness == .complete {
                value = response.data
                completeness = .complete
            } else if response.completeness == .prefix, response.data.first == 0x47 {
                value = response.data
                completeness = .prefix
            } else if response.completeness == .prefix, budgetLimit > initialMaximum {
                // 非 TS 资源在 1 MiB 截断时回退到完整拉取（受剩余 per-variant 上限约束）。
                let fullResponse = try await transport.fetch(.init(
                    url: resource.url,
                    headers: source.context.headers,
                    range: nil,
                    maximumBytes: budgetLimit,
                    deadline: deadline,
                    mode: .complete
                ))
                guard fullResponse.completeness == .complete else { throw HLSSourceError.incompleteEvidence }
                value = fullResponse.data
                completeness = .complete
            } else {
                throw HLSSourceError.incompleteEvidence
            }
        } else {
            let response = try await transport.fetch(.init(url: resource.url, headers: source.context.headers,
                range: resource.range, maximumBytes: budgetLimit, deadline: deadline))
            guard response.completeness == .complete || (resource.range != nil && response.completeness == .byteRange) else { throw HLSSourceError.incompleteEvidence }
            value = response.data
            completeness = .complete
        }
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        guard !value.isEmpty, value.count <= remaining, value.count <= resourceLimit,
              resource.range == nil || Int64(value.count) == resource.range?.length else { throw HLSSourceError.byteLimit }
        bytes += value.count
        if completeness == .complete {
            loaded[resource] = value
        }
        return (value, completeness)
    }
}
