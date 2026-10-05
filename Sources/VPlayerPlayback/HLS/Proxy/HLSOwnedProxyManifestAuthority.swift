// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct HLSProxyInitializationRenewal: Hashable {
    let original: HLSManifestGraph.Resource
    let originalEncryption: HLSManifestGraph.Encryption
    let replacement: HLSManifestGraph.Resource
    let replacementEncryption: HLSManifestGraph.Encryption
    fileprivate init(original: HLSManifestGraph.Resource, originalEncryption: HLSManifestGraph.Encryption,
                     replacement: HLSManifestGraph.Resource, replacementEncryption: HLSManifestGraph.Encryption) {
        self.original = original; self.originalEncryption = originalEncryption
        self.replacement = replacement; self.replacementEncryption = replacementEncryption
    }
}

/// The bytes actually validated and subsequently served. The domain lease precedes
/// I/O and stays with every snapshot/window/transfer alias, including retired windows.
final class HLSProxyProtectedBody: @unchecked Sendable {
    let url: URL
    let kind: HLSManifestGraph.ReferenceKind
    let range: HLSByteRange?
    let data: Data
    let contentRange: HLSHTTPContentRange?
    private let retention: HLSProxyBudget.Lease
    fileprivate init(resource: HLSManifestGraph.Resource, kind: HLSManifestGraph.ReferenceKind,
                     response: HLSResourceResponse, retention: HLSProxyBudget.Lease) {
        url = resource.url; range = resource.range; self.kind = kind
        data = response.data; contentRange = response.contentRange; self.retention = retention
    }
}

final class HLSProxyManifestSnapshot: @unchecked Sendable {
    let role: HLSProxyManifestRole
    let document: HLSManifestGraph.Document
    let mediaType: HLSProxyMediaType?
    let childRoles: [URL: HLSProxyManifestRole]
    let protectedBodies: [URL: HLSProxyProtectedBody]
    fileprivate let issuer: UUID
    fileprivate let generation: UInt64
    private let workspace: HLSApplicationLifetimeCharge
    private let sourceRetention: HLSApplicationLifetimeCharge
    fileprivate init(role: HLSProxyManifestRole, document: HLSManifestGraph.Document, mediaType: HLSProxyMediaType?,
                     childRoles: [URL: HLSProxyManifestRole], protectedBodies: [URL: HLSProxyProtectedBody],
                     issuer: UUID, generation: UInt64, workspace: HLSApplicationLifetimeCharge,
                     sourceRetention: HLSApplicationLifetimeCharge) {
        self.role = role; self.document = document; self.mediaType = mediaType; self.childRoles = childRoles
        self.protectedBodies = protectedBodies; self.issuer = issuer; self.generation = generation
        self.workspace = workspace; self.sourceRetention = sourceRetention
    }
}

/// Stable original roles, one bounded renewal, and no append-only locator cache.
/// Renewed locators preserve inspected expectations; they never mint codec facts.
final class HLSOwnedProxyManifestAuthority: @unchecked Sendable {
    private struct Role { let document: HLSManifestGraph.Document; let mediaType: HLSProxyMediaType? }
    private let owned: HLSOwnedSourcePlan
    private let graph: HLSManifestGraph?
    private let roles: [Role]
    private let originalRoles: [URL: HLSProxyManifestRole]
    private let metadata: HLSApplicationLifetimeCharge
    private let identity = UUID()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending: UInt64?
    private var retired = false
    private var initialConsumed: [Bool]
    private var sequenceFloors: [UInt64?]
    let rootRole: HLSProxyManifestRole?
    let rawMediaType: HLSProxyMediaType?

    init(owned: HLSOwnedSourcePlan) throws {
        metadata = try HLSApplicationLifetimeCharge(bytes: 128 * 1_024)
        self.owned = owned
        guard owned.isCurrent, owned.facts.complete, owned.facts.owner == owned.plan.owner,
              owned.facts.resolutionGeneration == owned.source.generation,
              owned.facts.formatFingerprint == owned.plan.formatFingerprint else { throw HLSSourceError.staleResolution }
        switch owned.source.topology {
        case let .hls(graph):
            self.graph = graph
            let documents = graph.orderedDocuments
            guard !documents.isEmpty, documents.count <= HLSManifestGraph.maximumDocuments,
                  graph.unsupportedFeatures.isEmpty else { throw HLSSourceError.graphLimit }
            var values: [Role] = [], indices: [URL: HLSProxyManifestRole] = [:]
            for document in documents {
                indices[document.responseURL] = .init(index: values.count)
                let matching = owned.facts.media.filter { $0.url == document.responseURL }
                guard document.kind == .master || matching.count == 1 else { throw HLSSourceError.incompleteEvidence }
                values.append(.init(document: document, mediaType: matching.first.flatMap { .init(container: $0.container) }))
            }
            guard let root = graph.document(for: graph.rootURL), let role = indices[root.responseURL] else { throw HLSSourceError.incompleteEvidence }
            roles = values; originalRoles = indices; rootRole = role; rawMediaType = nil
            initialConsumed = Array(repeating: false, count: values.count); sequenceFloors = Array(repeating: nil, count: values.count)
        case .media:
            guard owned.facts.media.count == 1, owned.facts.media[0].url == owned.source.responseURL else { throw HLSSourceError.incompleteEvidence }
            graph = nil; roles = []; originalRoles = [:]; rootRole = nil
            initialConsumed = []; sequenceFloors = []; rawMediaType = .init(container: owned.facts.media[0].container)
        }
    }

    func generatedServiceEndpoint() throws -> (url: URL, role: HLSProxyManifestRole) {
        guard owned.plan.transport == .generated, let selected = owned.plan.selectedServiceURL,
              let graph, let document = graph.document(for: selected), document.kind == .media,
              let role = originalRoles[document.responseURL] else { throw HLSSourceError.incompleteEvidence }
        // selectedMediaFacts additionally checks the original plan fingerprint,
        // owner and canonical response alias. A caller cannot pass an arbitrary URL.
        _ = try owned.selectedMediaFacts()
        return (selected, role)
    }

    private struct RenewalState {
        let deadline: UInt64
        let budget: HLSProxyBudget
        var bytes = 0, references = 0, protectionBytes = 0
        var locators: [HLSProxyManifestRole: URL] = [:]
        var bodies: [HLSManifestGraph.Resource: HLSProxyProtectedBody] = [:]
    }
    func load(role: HLSProxyManifestRole, requestedURL: URL, protectionBudget: HLSProxyBudget,
              transport: any HLSResourceTransport) async throws -> HLSProxyManifestSnapshot {
        try Task.checkCancellation()
        guard let graph, roles.indices.contains(role.index) else { throw HLSSourceError.unsupportedMedia }
        let claim = try currentSource { try lock.withLock { () -> (UInt64, Bool) in
            guard !retired, pending == nil, generation < UInt64.max else { throw HLSSourceError.staleResolution }
            generation += 1; pending = generation
            let reuse = !initialConsumed[role.index] && graph.document(for: requestedURL)?.responseURL == roles[role.index].document.responseURL
            initialConsumed[role.index] = true
            return (generation, reuse)
        } }
        do {
            let workspace = try HLSApplicationLifetimeCharge(bytes: claim.1 ? HLSPreflightMemoryLimits.resolverTemporary : HLSPreflightMemoryLimits.sourceRetention)
            let protection = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.probeTemporary)
            defer { withExtendedLifetime(protection) {} }
            var state = RenewalState(deadline: HLSMonotonicClock.deadline(seconds: 10), budget: protectionBudget)
            let document: HLSManifestGraph.Document
            if claim.1 {
                document = roles[role.index].document
                let renewals = try await renewProtection(document, original: document, ticket: claim.0, transport: transport, state: &state)
                try owned.validateManifest(document, original: document, initializationRenewals: renewals)
            } else {
                document = try await renew(role: role, url: requestedURL, depth: 0, ancestry: [], ticket: claim.0, transport: transport, state: &state)
            }
            try validate(ticket: claim.0)
            guard HLSMonotonicClock.now < state.deadline else { throw HLSSourceError.deadline }
            return .init(role: role, document: document, mediaType: roles[role.index].mediaType,
                childRoles: try children(of: document, role: role), protectedBodies: try protectedBodies(of: document, state: state),
                issuer: identity, generation: claim.0, workspace: workspace, sourceRetention: owned.sourceCharge)
        } catch { abandon(generation: claim.0); throw error }
    }

    private func renew(role: HLSProxyManifestRole, url: URL, depth: Int, ancestry: Set<HLSProxyManifestRole>,
                       ticket: UInt64, transport: any HLSResourceTransport, state: inout RenewalState) async throws -> HLSManifestGraph.Document {
        try validate(ticket: ticket)
        guard depth <= HLSManifestGraph.maximumDepth, !ancestry.contains(role),
              state.locators.count < HLSManifestGraph.maximumDocuments, HLSMonotonicClock.now < state.deadline else { throw HLSSourceError.graphLimit }
        if let prior = state.locators[role], prior != url { throw HLSSourceError.unsupportedMedia }
        state.locators[role] = url
        let remaining = HLSManifestGraph.maximumGraphBytes - state.bytes
        guard remaining > 0 else { throw HLSSourceError.byteLimit }
        let response = try await transport.fetch(.init(url: url, headers: owned.source.context.headers,
            maximumBytes: min(remaining, HLSManifestGraph.maximumPlaylistBytes), deadline: state.deadline))
        try validate(ticket: ticket)
        guard HLSMonotonicClock.now < state.deadline, response.completeness == .complete, response.data.count <= remaining else { throw HLSSourceError.incompleteEvidence }
        state.bytes += response.data.count
        let parsed = try HLSManifestGraph.parse(data: response.data, responseURL: response.responseURL)
        guard let document = parsed.document(for: response.responseURL) else { throw HLSSourceError.malformedManifest }
        let renewals = try await renewProtection(document, original: roles[role.index].document, ticket: ticket, transport: transport, state: &state)
        try owned.validateManifest(document, original: roles[role.index].document, initializationRenewals: renewals)
        try validate(ticket: ticket)
        state.references += document.references.count
        guard state.references <= HLSManifestGraph.maximumReferences else { throw HLSSourceError.graphLimit }
        let children = try children(of: document, role: role)
        var nextAncestry = ancestry; nextAncestry.insert(role)
        for reference in document.references where [.variant, .rendition, .iframe].contains(reference.kind) {
            guard let child = children[reference.url] else { throw HLSSourceError.incompleteEvidence }
            if let prior = state.locators[child] {
                guard !nextAncestry.contains(child), prior == reference.url else { throw HLSSourceError.unsupportedMedia }
                continue
            }
            _ = try await renew(role: child, url: reference.url, depth: depth + 1, ancestry: nextAncestry, ticket: ticket, transport: transport, state: &state)
        }
        guard HLSMonotonicClock.now < state.deadline else { throw HLSSourceError.deadline }
        return document
    }

    private func renewProtection(_ document: HLSManifestGraph.Document, original: HLSManifestGraph.Document,
                                 ticket: UInt64, transport: any HLSResourceTransport,
                                 state: inout RenewalState) async throws -> Set<HLSProxyInitializationRenewal> {
        guard document.unsupportedFeatures.isEmpty, document.kind == original.kind,
              try HLSManifestRewriter.protectionContracts(document).isSubset(of: HLSManifestRewriter.protectionContracts(original)) else {
            throw HLSSourceError.unsupportedMedia
        }
        for reference in document.references where reference.kind == .key {
            _ = try await key(reference.url, ticket: ticket, transport: transport, state: &state)
        }
        var result: Set<HLSProxyInitializationRenewal> = []
        for segment in document.segments {
            guard let replacement = segment.initialization else { continue }
            if result.contains(where: { $0.replacement == replacement && $0.replacementEncryption == segment.initializationEncryption }) { continue }
            guard let first = original.segments.first, let previous = first.initialization, previous.range == replacement.range,
                  let expected = owned.facts.initializationReceipts.plaintextByteCount(source: owned.source,
                    originalMediaURL: original.responseURL, originalResource: previous, originalEncryption: first.initializationEncryption),
                  expected > 0, expected <= HLSCompatibilityProbe.maximumBytes else { throw HLSSourceError.incompleteEvidence }
            try validate(ticket: ticket)
            let maximum: Int
            switch (first.initializationEncryption, segment.initializationEncryption) {
            case (.none, .none): maximum = expected
            case (.aes128, .aes128):
                guard replacement.range == nil else { throw HLSSourceError.unsupportedMedia }
                maximum = (expected / 16 + 1) * 16
            default: throw HLSSourceError.unsupportedMedia
            }
            let response = try await protectionBody(replacement, kind: .initialization, maximum: maximum,
                ticket: ticket, transport: transport, state: &state)
            let plaintext: Data
            switch segment.initializationEncryption {
            case .none: plaintext = response.data
            case let .aes128(url, iv):
                let key = try await key(url, ticket: ticket, transport: transport, state: &state)
                try admitProtectionBytes(response.data.count + HLSAES128Preflight.workspaceBytes, state: &state)
                plaintext = try HLSAES128Preflight.decrypt(response.data, key: key, iv: iv)
            }
            try validate(ticket: ticket)
            // These receipt methods acquire the source fence themselves. Never
            // nest them inside currentSource's nonrecursive resolution lock.
            guard owned.facts.initializationReceipts.matches(plaintext: plaintext, source: owned.source,
                originalMediaURL: original.responseURL, originalResource: previous, originalEncryption: first.initializationEncryption,
                replacementRange: replacement.range, replacementEncryption: segment.initializationEncryption) else { throw HLSSourceError.unsupportedMedia }
            try validate(ticket: ticket)
            guard HLSMonotonicClock.now < state.deadline else { throw HLSSourceError.deadline }
            state.bodies[replacement] = response
            result.insert(.init(original: previous, originalEncryption: first.initializationEncryption,
                replacement: replacement, replacementEncryption: segment.initializationEncryption))
        }
        return result
    }
    private func key(_ url: URL, ticket: UInt64, transport: any HLSResourceTransport, state: inout RenewalState) async throws -> Data {
        let resource = HLSManifestGraph.Resource(url: url, range: nil)
        let response = try await protectionBody(resource, kind: .key, maximum: 16, ticket: ticket, transport: transport, state: &state)
        guard response.data.count == 16 else { throw HLSSourceError.unsupportedMedia }
        state.bodies[resource] = response
        return response.data
    }
    private func protectionBody(_ resource: HLSManifestGraph.Resource, kind: HLSManifestGraph.ReferenceKind,
                                maximum: Int, ticket: UInt64, transport: any HLSResourceTransport,
                                state: inout RenewalState) async throws -> HLSProxyProtectedBody {
        try validate(ticket: ticket)
        if let cached = state.bodies[resource] {
            guard cached.kind == kind, cached.data.count == maximum, cached.range == resource.range else { throw HLSSourceError.unsupportedMedia }
            return cached
        }
        guard state.bodies.count < HLSManifestGraph.maximumReferences, maximum > 0,
              maximum <= HLSCompatibilityProbe.maximumBytes - state.protectionBytes,
              HLSMonotonicClock.now < state.deadline else { throw HLSSourceError.byteLimit }
        let retention = try state.budget.reserve(bytes: maximum + 1_024 + 4 * resource.url.absoluteString.utf8.count)
        let response = try await transport.fetch(.init(url: resource.url, headers: owned.source.context.headers,
            range: resource.range, maximumBytes: maximum, deadline: state.deadline))
        try validate(ticket: ticket)
        guard HLSMonotonicClock.now < state.deadline, response.data.count == maximum else { throw HLSSourceError.incompleteEvidence }
        if let range = resource.range {
            guard response.completeness == .byteRange || response.completeness == .complete,
                  response.contentRange?.start == range.offset, response.contentRange?.length == range.length,
                  Int64(response.data.count) == range.length else { throw HLSSourceError.incompleteEvidence }
        } else { guard response.completeness == .complete else { throw HLSSourceError.incompleteEvidence } }
        try admitProtectionBytes(response.data.count, state: &state)
        return .init(resource: resource, kind: kind, response: response, retention: retention)
    }
    private func admitProtectionBytes(_ count: Int, state: inout RenewalState) throws {
        guard count >= 0, count <= HLSCompatibilityProbe.maximumBytes - state.protectionBytes else { throw HLSSourceError.byteLimit }
        state.protectionBytes += count
    }
    private func protectedBodies(of document: HLSManifestGraph.Document, state: RenewalState) throws -> [URL: HLSProxyProtectedBody] {
        var result: [URL: HLSProxyProtectedBody] = [:]
        for reference in document.references where reference.kind == .key || reference.kind == .initialization {
            let resource: HLSManifestGraph.Resource
            if reference.kind == .key { resource = .init(url: reference.url, range: nil) }
            else {
                guard let map = document.segments.compactMap(\.initialization).first(where: { $0.url == reference.url }) else { throw HLSSourceError.incompleteEvidence }
                resource = map
            }
            guard let body = state.bodies[resource], body.kind == reference.kind,
                  result[reference.url] == nil || result[reference.url] === body else { throw HLSSourceError.incompleteEvidence }
            result[reference.url] = body
        }
        return result
    }
    private func children(of document: HLSManifestGraph.Document, role: HLSProxyManifestRole) throws -> [URL: HLSProxyManifestRole] {
        guard let graph else { return [:] }
        let old = roles[role.index].document.references.filter { [.variant, .rendition, .iframe].contains($0.kind) }
        let current = document.references.filter { [.variant, .rendition, .iframe].contains($0.kind) }
        guard old.count == current.count else { throw HLSSourceError.unsupportedMedia }
        var result: [URL: HLSProxyManifestRole] = [:], destinations: [HLSProxyManifestRole: URL] = [:]
        for (previous, next) in zip(old, current) {
            guard previous.kind == next.kind, let original = graph.document(for: previous.url), let child = originalRoles[original.responseURL],
                  result[next.url] == nil || result[next.url] == child,
                  destinations[child] == nil || destinations[child] == next.url else { throw HLSSourceError.unsupportedMedia }
            result[next.url] = child; destinations[child] = next.url
        }
        return result
    }
    func publish<T>(_ snapshot: HLSProxyManifestSnapshot, _ operation: () throws -> T) throws -> T {
        try currentSource { try lock.withLock {
            guard !retired, snapshot.issuer == identity, pending == snapshot.generation, generation == snapshot.generation else { throw HLSSourceError.staleResolution }
            if let sequence = snapshot.document.segments.first?.mediaSequence,
               let floor = sequenceFloors[snapshot.role.index], sequence < floor { throw HLSSourceError.staleResolution }
            let result = try operation()
            sequenceFloors[snapshot.role.index] = snapshot.document.segments.first?.mediaSequence
            pending = nil
            return result
        } }
    }
    func abandon(_ snapshot: HLSProxyManifestSnapshot) { if snapshot.issuer == identity { abandon(generation: snapshot.generation) } }
    private func abandon(generation: UInt64) { lock.withLock { if pending == generation { pending = nil } } }
    private func validate(ticket: UInt64) throws {
        try Task.checkCancellation()
        try currentSource { try lock.withLock {
            guard !retired, pending == ticket, generation == ticket else { throw HLSSourceError.staleResolution }
        } }
    }
    private func currentSource<T>(_ operation: () throws -> T) throws -> T {
        guard let result = try owned.source.withCurrentResolution(owner: owned.plan.owner, generation: owned.source.generation, operation: operation) else {
            throw HLSSourceError.staleResolution
        }
        return result
    }
    func retire() { lock.withLock { retired = true; pending = nil } }
}
