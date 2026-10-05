// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Network

enum HLSByteProxy {
    static func start(source: ResolvedPlaybackSource, lifecycle: OutputLifecycleEpoch,
                      resolver: any PlaybackSourceResolving, sourceRetention: HLSApplicationLifetimeCharge? = nil,
                      manifestAuthority: HLSOwnedProxyManifestAuthority? = nil,
                      manifestTransport: any HLSResourceTransport = URLSessionHLSResourceTransport(),
                      validateManifest: (@Sendable (URL, HLSManifestGraph.Document) async throws -> Void)? = nil,
                      failure: @escaping @Sendable (HLSSourceError) -> Void = { _ in }) async throws -> HLSProxySession {
        guard source.context.owner?.backendIdentity == lifecycle.backendIdentity,
              source.context.owner?.outputLifecycleNonce == lifecycle.outputNonce else { throw HLSSourceError.unboundOwner }
        let budget = try HLSProxyBudget()
        let registry = try HLSProxyResourceRegistry(source: source, budget: budget, sourceRetention: sourceRetention)
        let kind: HLSManifestGraph.ReferenceKind
        let url: URL
        switch source.topology {
        case .hls: kind = .variant; url = source.context.entryURL
        case .media: kind = .segment; url = source.responseURL
        }
        let root = try registry.register(url: url, kind: kind, pin: true,
            mediaType: .reference(kind, url: url, provenMedia: manifestAuthority?.rawMediaType), manifestRole: manifestAuthority?.rootRole)
        let session = try HLSProxySession(source: source, root: root, resolver: resolver, registry: registry, budget: budget,
            manifestAuthority: manifestAuthority, manifestTransport: manifestTransport, validator: validateManifest, failure: failure)
        do { try await session.start(); return session }
        catch { _ = await session.retire(); throw error }
    }
}

final class HLSProxySession: @unchecked Sendable {
    private let source: ResolvedPlaybackSource
    private let resolver: any PlaybackSourceResolving
    private let registry: HLSProxyResourceRegistry
    private let budget: HLSProxyBudget
    private let root: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.vplayer.byte-proxy")
    private let lock = NSLock()
    private let authority: HLSOwnedProxyManifestAuthority?
    private let transport: any HLSResourceTransport
    private let validator: (@Sendable (URL, HLSManifestGraph.Document) async throws -> Void)?
    private let failure: @Sendable (HLSSourceError) -> Void
    private var connections: [UUID: HLSProxyConnection] = [:]
    private var closing = false, listenerCancelled = false, manifestInFlight = false
    private var port: UInt16 = 0
    private var startup: CheckedContinuation<Void, any Error>?
    private var listenerStopped: CheckedContinuation<Void, Never>?
    private var retirement: Task<Bool, Never>?
    private let io = HLSProxyIOCounters()
    var itemURL: URL { lock.withLock { URL(string: "http://127.0.0.1:\(port)\(root)")! } }
    var resourceCount: Int { registry.entryCount }
    var admissionUsage: (bytes: Int, transfers: Int, connections: Int) { budget.usage }
    var observedIO: HLSProxyIOCounters.Snapshot { io.snapshot }
    #if DEBUG
    private var protectedTransferGate: (@Sendable (String) async -> Void)?
    func resourceLeaseForTesting(path: String) throws -> HLSProxyResourceRegistry.Resource { try registry.lease(path: path) }
    func holdProtectedTransferForTesting(_ body: @escaping @Sendable (String) async -> Void) {
        lock.withLock { protectedTransferGate = body }
    }
    #endif

    fileprivate init(source: ResolvedPlaybackSource, root: String, resolver: any PlaybackSourceResolving,
                     registry: HLSProxyResourceRegistry, budget: HLSProxyBudget, manifestAuthority: HLSOwnedProxyManifestAuthority?,
                     manifestTransport: any HLSResourceTransport, validator: (@Sendable (URL, HLSManifestGraph.Document) async throws -> Void)?,
                     failure: @escaping @Sendable (HLSSourceError) -> Void) throws {
        self.source = source; self.root = root; self.resolver = resolver; self.registry = registry; self.budget = budget
        authority = manifestAuthority; transport = manifestTransport; self.validator = validator; self.failure = failure
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false; parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        listener = try NWListener(using: parameters)
    }
    fileprivate func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { startup = continuation }
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.stateUpdateHandler = { [weak self] in self?.listenerState($0) }
                listener.start(queue: queue)
            }
            try Task.checkCancellation()
        } onCancel: { self.listener.cancel() }
    }
    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard !closing, let port = listener.port else { return nil }
                self.port = port.rawValue; defer { startup = nil }; return startup
            }
            pending?.resume()
        case .failed:
            let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in defer { startup = nil }; return startup }
            pending?.resume(throwing: HLSSourceError.network); listener.cancel()
        case .cancelled:
            let pending = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, CheckedContinuation<Void, Never>?) in
                listenerCancelled = true; defer { startup = nil; listenerStopped = nil }; return (startup, listenerStopped)
            }
            pending.0?.resume(throwing: CancellationError()); pending.1?.resume()
        default: break
        }
    }
    private func accept(_ connection: NWConnection) {
        do {
            let lease = try budget.admitConnection()
            let worker = HLSProxyConnection(connection: connection, lease: lease, io: io)
            guard lock.withLock({ () -> Bool in
                guard !closing, connections.count < HLSProxyBudget.maximumConnections else { return false }
                connections[worker.id] = worker; return true
            }) else { connection.cancel(); return }
            worker.start(queue: queue) { [self, worker] in
                await handle(worker)
                await worker.closeAndJoin()
                lock.withLock { _ = connections.removeValue(forKey: worker.id) }
            }
        } catch { connection.cancel() }
    }
    private func handle(_ connection: HLSProxyConnection) async {
        do {
            let port = lock.withLock { self.port }
            try await connection.awaitReady(port: port)
            let request = try await connection.readRequest()
            try HLSProxyHTTP.authorize(request, port: port, prefix: registry.prefix)
            let resource = try registry.lease(path: request.target)
            guard !lock.withLock({ closing }) else { throw HLSSourceError.retired }
            if source.refreshReason() != nil { throw HLSSourceError.staleResolution }
            let transfer = try budget.admitTransfer()
            if resource.isPlaylist {
                guard lock.withLock({ () -> Bool in guard !manifestInFlight else { return false }; manifestInFlight = true; return true }) else {
                    try await connection.sendStatus(503); return
                }
                defer { lock.withLock { manifestInFlight = false } }
                let workspace = try budget.reserve(bytes: 8 * 1_024 * 1_024)
                let snapshot: HLSProxyManifestSnapshot?
                let document: HLSManifestGraph.Document
                var legacyTemporary: HLSApplicationLifetimeCharge?
                if let authority {
                    guard let role = resource.manifestRole else { throw HLSSourceError.incompleteEvidence }
                    let loaded = try await authority.load(role: role, requestedURL: resource.url, protectionBudget: budget, transport: transport)
                    snapshot = loaded; document = loaded.document
                } else {
                    snapshot = nil
                    legacyTemporary = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.resolverTemporary)
                    let response = try await transport.fetch(.init(url: resource.url, headers: source.context.headers,
                        maximumBytes: HLSManifestGraph.maximumPlaylistBytes, deadline: HLSMonotonicClock.deadline(seconds: 10)))
                    let graph = try HLSManifestGraph.parse(data: response.data, responseURL: response.responseURL)
                    guard response.completeness == .complete, let parsed = graph.document(for: response.responseURL),
                          parsed.unsupportedFeatures.isEmpty else { throw HLSSourceError.unsupportedMedia }
                    document = parsed
                }
                defer { if let snapshot { authority?.abandon(snapshot) } }
                try Task.checkCancellation()
                guard await resolver.isCurrent(source), !lock.withLock({ closing }) else { throw HLSSourceError.staleResolution }
                try await validator?(resource.url, document)
                try Task.checkCancellation()
                func rewrite() throws -> Data {
                    try registry.beginManifestUpdate(documentURL: resource.url, role: snapshot?.role)
                    do {
                        let bytes = try HLSManifestRewriter.rewrite(document, registry: registry, mediaType: snapshot?.mediaType,
                            childRoles: snapshot?.childRoles ?? [:], protectedBodies: snapshot?.protectedBodies)
                        registry.finishManifestUpdate(); return bytes
                    } catch { registry.abandonManifestUpdate(); throw error }
                }
                let bytes: Data
                if let snapshot, let authority { bytes = try authority.publish(snapshot, rewrite) }
                else {
                    guard let owner = source.context.owner,
                          let value = try source.withCurrentResolution(owner: owner, generation: source.generation, operation: rewrite) else { throw HLSSourceError.staleResolution }
                    bytes = value
                }
                try await connection.send(body: bytes, method: request.method, contentType: "application/vnd.apple.mpegurl", range: request.values(forHeader: "Range").first)
                withExtendedLifetime((workspace, legacyTemporary, snapshot)) {}
            } else if let body = resource.protectedBody {
                #if DEBUG
                let gate = lock.withLock { protectedTransferGate }
                await gate?(request.target)
                #endif
                try await connection.send(protectedBody: body, method: request.method, range: request.values(forHeader: "Range").first)
                withExtendedLifetime((resource, body)) {}
            } else {
                let operation = HLSProxyUpstream(resource: resource, method: request.method,
                    range: try HLSProxyHTTP.validatedRange(request.values(forHeader: "Range").first), connection: connection, transfer: transfer)
                connection.installUpstream(operation)
                try await operation.run()
                connection.installUpstream(nil)
            }
            withExtendedLifetime(transfer) {}
        } catch {
            if !Task.isCancelled {
                let error = (error as? HLSSourceError) ?? .network
                if error == .unauthorized || error == .staleResolution || error == .unsupportedMedia { failure(error) }
                try? await connection.sendStatus(error == .retired ? 410 : 502)
            }
        }
    }
    func retire() async -> Bool {
        let task = lock.withLock { () -> Task<Bool, Never> in
            if let retirement { return retirement }
            closing = true; authority?.retire(); registry.retire()
            let current = Array(connections.values)
            let task = Task { [self] in
                listener.cancel()
                for worker in current { worker.cancel() }
                for worker in current { await worker.joinWork() }
                await withCheckedContinuation { continuation in
                    let finished = lock.withLock { () -> Bool in
                        if listenerCancelled { return true }; listenerStopped = continuation; return false
                    }
                    if finished { continuation.resume() }
                }
                await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
                listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil
                return lock.withLock { connections.isEmpty }
            }
            retirement = task; return task
        }
        return await task.value
    }
}
