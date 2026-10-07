// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum SourceResolutionReason: Sendable, Equatable { case initial, unauthorized, expired, topologyChanged }
public struct ResolvedPlaybackSource: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Topology: Sendable { case hls(HLSManifestGraph), media(Data) }
    public let context: PlaybackSourceContext
    public let responseURL: URL
    public let generation: UInt64
    public let topology: Topology
    public let mediaCompleteness: HLSMediaCompleteness
    private let validity = SourceResolutionValidity()
    public init(context: PlaybackSourceContext, responseURL: URL, generation: UInt64, topology: Topology, mediaCompleteness: HLSMediaCompleteness = .complete) {
        self.context = context; self.responseURL = responseURL; self.generation = generation; self.topology = topology; self.mediaCompleteness = mediaCompleteness
    }
    public var requiresManagedTransport: Bool { !context.headers.isEmpty || context.explicitExpiry != nil }
    public func refreshReason(at date: Date = Date(), responseStatus: Int? = nil) -> SourceResolutionReason? {
        if responseStatus == 401 || responseStatus == 403 { return .unauthorized }
        if let expiry = context.explicitExpiry, date >= expiry { return .expired }
        return nil
    }
    public func withCurrentResolution<T>(owner: PlaybackSourceOwner, generation: UInt64, operation: () throws -> T) rethrows -> T? {
        guard context.owner == owner, self.generation == generation else { return nil }
        return try validity.withCurrent(operation)
    }
    fileprivate func retire() { validity.retire() }
    public var description: String { "ResolvedPlaybackSource(generation=\(generation), transport=redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["generation": generation, "transport": "redacted"]) }
}
fileprivate final class SourceResolutionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    func retire() { lock.withLock { current = false } }
    func withCurrent<T>(_ operation: () throws -> T) rethrows -> T? {
        try lock.withLock { guard current else { return nil }; return try operation() }
    }
}
public protocol PlaybackSourceResolving: Sendable {
    func resolve(_ context: PlaybackSourceContext, reason: SourceResolutionReason) async throws -> ResolvedPlaybackSource
    func isCurrent(_ source: ResolvedPlaybackSource) async -> Bool
    func invalidate() async
}

/// One exact prepare/lifecycle owner. A superseded load is cancelled AND joined
/// before its replacement can allocate another graph workspace.
public actor URLSessionPlaybackSourceResolver: PlaybackSourceResolving {
    private let transport: any HLSResourceTransport
    private var owner: PlaybackSourceOwner?
    private var generation: UInt64 = 0
    private var current: ResolvedPlaybackSource?
    private var active: Task<ResolvedPlaybackSource, any Error>?
    private var retired = false
    public init(transport: any HLSResourceTransport = URLSessionHLSResourceTransport()) { self.transport = transport }
    public func resolve(_ context: PlaybackSourceContext, reason: SourceResolutionReason) async throws -> ResolvedPlaybackSource {
        try Task.checkCancellation()
        guard !retired else { throw HLSSourceError.retired }
        guard let requestedOwner = context.owner, owner == nil || owner == requestedOwner else { throw HLSSourceError.unboundOwner }
        guard generation < UInt64.max else { throw HLSSourceError.retired }
        owner = requestedOwner; generation += 1
        let candidate = generation
        current?.retire(); current = nil
        if let previous = active {
            previous.cancel()
            _ = await previous.result
            try Task.checkCancellation()
            guard !retired, generation == candidate else { throw HLSSourceError.staleResolution }
            active = nil
        }
        let transport = self.transport
        let task = Task { try await SourceGraphLoader(transport: transport).load(context: context, generation: candidate) }
        active = task
        return try await withTaskCancellationHandler {
            do {
                let source = try await task.value
                do { try Task.checkCancellation() } catch { source.retire(); throw error }
                guard !retired, owner == requestedOwner, generation == candidate else { source.retire(); throw HLSSourceError.staleResolution }
                active = nil; current = source; return source
            } catch {
                if generation == candidate { active = nil; current = nil }
                throw error
            }
        } onCancel: { task.cancel() }
    }
    public func isCurrent(_ source: ResolvedPlaybackSource) -> Bool {
        !retired && source.context.owner == owner && source.context == current?.context && source.generation == generation && current?.generation == generation
    }
    public func invalidate() async {
        retired = true; current?.retire(); current = nil
        let pending = active; pending?.cancel()
        if let pending { _ = await pending.result }
        active = nil
    }
}

private struct SourceGraphLoader: Sendable {
    let transport: any HLSResourceTransport
    func load(context: PlaybackSourceContext, generation: UInt64) async throws -> ResolvedPlaybackSource {
        let deadline = HLSMonotonicClock.deadline(seconds: 10)
        let root = try await transport.fetch(.init(url: context.entryURL, headers: context.headers,
            maximumBytes: HLSManifestGraph.maximumPlaylistBytes, deadline: deadline, mode: .classify,
            maximumTSContinuationBytes: HLSCompatibilityProbe.maximumBytes))
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        guard !root.data.isEmpty, root.data.count <= HLSCompatibilityProbe.maximumBytes else { throw HLSSourceError.byteLimit }
        // Only a raw TS candidate may use the continuation ceiling. This is a
        // byte bound, not format acceptance; the ordinary probe still proves it.
        guard root.data.count <= HLSManifestGraph.maximumPlaylistBytes || root.data.first == 0x47 else { throw HLSSourceError.byteLimit }
        if !root.data.starts(with: Data("#EXTM3U".utf8)) {
            return ResolvedPlaybackSource(context: context, responseURL: root.responseURL, generation: generation,
                topology: .media(root.data), mediaCompleteness: root.completeness == .complete ? .complete : .prefix)
        }
        guard root.data.count <= HLSManifestGraph.maximumPlaylistBytes else { throw HLSSourceError.byteLimit }
        guard root.completeness == .complete else { throw HLSSourceError.incompleteEvidence }
        let builder = SourceManifestGraphBuilder(transport: transport, context: context, deadline: deadline)
        let graph = try await builder.build(root: root)
        return ResolvedPlaybackSource(context: context, responseURL: root.responseURL, generation: generation, topology: .hls(graph))
    }
}

/// Confined to one load task. DFS ancestry distinguishes true cycles from shared
/// rendition nodes; requested aliases and actual response URLs both retain identity.
private final class SourceManifestGraphBuilder {
    private let transport: any HLSResourceTransport
    private let context: PlaybackSourceContext
    private let deadline: UInt64
    private var documents: [URL: HLSManifestGraph.Document] = [:]
    private var aliases: [URL: URL] = [:]
    private var bytes = 0
    private var references = 0
    init(transport: any HLSResourceTransport, context: PlaybackSourceContext, deadline: UInt64) {
        self.transport = transport; self.context = context; self.deadline = deadline
    }
    func build(root: HLSResourceResponse) async throws -> HLSManifestGraph {
        try await visit(context.entryURL, supplied: root, depth: 0, ancestry: [])
        return HLSManifestGraph(rootURL: root.responseURL, documents: documents, aliases: aliases)
    }
    private func visit(_ requestedURL: URL, supplied: HLSResourceResponse? = nil, depth: Int, ancestry: Set<URL>) async throws {
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        guard depth <= HLSManifestGraph.maximumDepth else { throw HLSSourceError.graphLimit }
        let known = aliases[requestedURL] ?? requestedURL
        guard !ancestry.contains(requestedURL), !ancestry.contains(known) else { throw HLSSourceError.graphLimit }
        if documents[known] != nil { return }
        guard documents.count < HLSManifestGraph.maximumDocuments, aliases.count < HLSManifestGraph.maximumReferences else { throw HLSSourceError.graphLimit }
        let remaining = HLSManifestGraph.maximumGraphBytes - bytes
        guard remaining > 0 else { throw HLSSourceError.byteLimit }
        let response: HLSResourceResponse
        if let supplied { response = supplied }
        else { response = try await transport.fetch(.init(url: requestedURL, headers: context.headers,
            maximumBytes: min(HLSManifestGraph.maximumPlaylistBytes, remaining), deadline: deadline)) }
        try Task.checkCancellation()
        guard HLSMonotonicClock.now < deadline else { throw HLSSourceError.deadline }
        guard response.completeness == .complete else { throw HLSSourceError.incompleteEvidence }
        guard response.data.count <= remaining, response.data.count <= HLSManifestGraph.maximumPlaylistBytes else { throw HLSSourceError.byteLimit }
        guard !ancestry.contains(response.responseURL) else { throw HLSSourceError.graphLimit }
        bytes += response.data.count
        aliases[requestedURL] = response.responseURL
        aliases[response.responseURL] = response.responseURL
        guard aliases.count <= HLSManifestGraph.maximumReferences else { throw HLSSourceError.graphLimit }
        if documents[response.responseURL] != nil { return }
        let parsed = try HLSManifestGraph.parse(data: response.data, responseURL: response.responseURL)
        guard let document = parsed.document(for: response.responseURL) else { throw HLSSourceError.malformedManifest }
        guard document.references.count <= HLSManifestGraph.maximumReferences - references else { throw HLSSourceError.graphLimit }
        references += document.references.count; documents[response.responseURL] = document
        var next = ancestry; next.insert(requestedURL); next.insert(response.responseURL)
        for child in document.playlistURLs { try await visit(child, depth: depth + 1, ancestry: next) }
    }
}
