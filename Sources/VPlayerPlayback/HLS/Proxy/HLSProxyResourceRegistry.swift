// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct HLSProxyManifestRole: Hashable, Sendable { let index: Int }

enum HLSProxyMediaType: String, Sendable {
    case playlist = "m3u8", transportStream = "ts", isoBMFF = "mp4", webVTT = "vtt"
    case aac, ac3, eac3, mp3, key, opaque = "bin"

    init?(container: HLSMediaFacts.Container) {
        switch container {
        case .mpegTS: self = .transportStream
        case .fragmentedMP4, .isoBMFF: self = .isoBMFF
        case .webVTT: self = .webVTT
        case .unknown: return nil
        }
    }

    static func reference(_ kind: HLSManifestGraph.ReferenceKind, url: URL,
                          provenMedia: Self? = nil) -> Self {
        switch kind {
        case .variant, .rendition, .iframe: return .playlist
        case .key: return .key
        case .segment, .initialization:
            if let provenMedia { return provenMedia }
            switch url.pathExtension.lowercased() {
            case "ts", "m2ts", "mts": return .transportStream
            case "mp4", "m4s", "m4a", "m4v", "mov", "3gp", "cmfv", "cmfa", "fmp4": return .isoBMFF
            case "vtt", "webvtt": return .webVTT
            case "aac": return .aac
            case "ac3": return .ac3
            case "eac3", "ec3": return .eac3
            case "mp3": return .mp3
            default: return .opaque
            }
        }
    }
}

/// Exact immutable transport leases. A protected response has its own identity,
/// even when a later playlist repeats the same mutable upstream URL.
final class HLSProxyResourceRegistry: @unchecked Sendable {
    final class Resource: @unchecked Sendable {
        let url: URL
        let kind: HLSManifestGraph.ReferenceKind
        let mediaType: HLSProxyMediaType
        let manifestRole: HLSProxyManifestRole?
        let source: ResolvedPlaybackSource
        let protectedBody: HLSProxyProtectedBody?
        private let sourceRetention: HLSApplicationLifetimeCharge?
        private let budgetLease: HLSProxyBudget.Lease

        fileprivate init(url: URL, kind: HLSManifestGraph.ReferenceKind, mediaType: HLSProxyMediaType,
                         manifestRole: HLSProxyManifestRole?, source: ResolvedPlaybackSource,
                         protectedBody: HLSProxyProtectedBody?, sourceRetention: HLSApplicationLifetimeCharge?,
                         budgetLease: HLSProxyBudget.Lease) {
            self.url = url; self.kind = kind; self.mediaType = mediaType; self.manifestRole = manifestRole
            self.source = source; self.protectedBody = protectedBody
            self.sourceRetention = sourceRetention; self.budgetLease = budgetLease
        }
        var isPlaylist: Bool { [.variant, .rendition, .iframe].contains(kind) }
    }

    private struct ResourceIdentity: Hashable {
        let url: URL
        let protectedBody: ObjectIdentifier?
    }
    private struct ManifestWindow {
        var paths: Set<String> = []
        var charges: [HLSProxyBudget.Lease] = []
    }
    private enum WindowIdentity: Hashable { case role(HLSProxyManifestRole), legacyURL(URL) }
    let prefix: String
    private let source: ResolvedPlaybackSource
    private let retention: HLSApplicationLifetimeCharge?
    private let budget: HLSProxyBudget
    private let lock = NSLock()
    private var entries: [String: Resource] = [:]
    private var reverse: [ResourceIdentity: String] = [:]
    private var next: UInt64 = 0
    private var windows: [WindowIdentity: [ManifestWindow]] = [:]
    private var pending: (identity: WindowIdentity, window: ManifestWindow)?
    private var pinned: Set<String> = []
    private var retired = false

    init(source: ResolvedPlaybackSource, budget: HLSProxyBudget,
         sourceRetention: HLSApplicationLifetimeCharge? = nil) throws {
        self.source = source; self.budget = budget; retention = sourceRetention
        prefix = "/proxy/\(try LoopbackSessionToken.generateSystemCapability().value)/"
    }
    var entryCount: Int { lock.withLock { entries.count } }

    func beginManifestUpdate(documentURL: URL? = nil, role: HLSProxyManifestRole? = nil) throws {
        try lock.withLock {
            guard !retired, pending == nil else { throw HLSSourceError.retired }
            let identity = role.map(WindowIdentity.role) ?? .legacyURL(documentURL ?? source.responseURL)
            guard windows[identity] != nil || windows.count < HLSManifestGraph.maximumDocuments else { throw HLSSourceError.graphLimit }
            pending = (identity, ManifestWindow())
        }
    }
    func finishManifestUpdate() {
        lock.withLock {
            guard let pending else { return }
            var history = windows[pending.identity] ?? []
            history.append(pending.window)
            if history.count > 3 { history.removeFirst() }
            windows[pending.identity] = history
            self.pending = nil
            removeUnreferencedLocked()
        }
    }
    func abandonManifestUpdate() { lock.withLock { pending = nil; removeUnreferencedLocked() } }
    private func removeUnreferencedLocked() {
        let retained = windows.values.flatMap { $0 }.reduce(into: pinned) { $0.formUnion($1.paths) }
        for path in entries.keys.filter({ !retained.contains($0) }) {
            if let value = entries.removeValue(forKey: path) {
                reverse.removeValue(forKey: .init(url: value.url, protectedBody: value.protectedBody.map(ObjectIdentifier.init)))
            }
        }
    }

    func register(url: URL, kind: HLSManifestGraph.ReferenceKind, pin: Bool = false,
                  mediaType: HLSProxyMediaType? = nil, manifestRole: HLSProxyManifestRole? = nil,
                  protectedBody: HLSProxyProtectedBody? = nil) throws -> String {
        let mediaType = mediaType ?? HLSProxyMediaType.reference(kind, url: url)
        return try lock.withLock {
            guard !retired else { throw HLSSourceError.retired }
            _ = try PlaybackSourceOrigin(url)
            guard url.absoluteString.utf8.count <= 8_192 else { throw HLSSourceError.byteLimit }
            if let protectedBody {
                guard protectedBody.url == url, protectedBody.kind == kind else { throw HLSSourceError.unsupportedMedia }
            }
            let identity = ResourceIdentity(url: url, protectedBody: protectedBody.map(ObjectIdentifier.init))
            if let path = reverse[identity], let entry = entries[path] {
                guard entry.isPlaylist == [.variant, .rendition, .iframe].contains(kind),
                      entry.mediaType == mediaType, entry.manifestRole == manifestRole else { throw HLSSourceError.unsupportedMedia }
                try retainPathLocked(path, pin: pin)
                return path
            }
            guard entries.count < 4_096, next < UInt64.max else { throw HLSSourceError.graphLimit }
            let lease = try budget.reserve(bytes: 1_024 + 4 * url.absoluteString.utf8.count)
            next += 1
            let path = prefix + String(next) + "." + mediaType.rawValue
            entries[path] = Resource(url: url, kind: kind, mediaType: mediaType, manifestRole: manifestRole,
                source: source, protectedBody: protectedBody, sourceRetention: retention, budgetLease: lease)
            reverse[identity] = path
            try retainPathLocked(path, pin: pin)
            return path
        }
    }
    private func retainPathLocked(_ path: String, pin: Bool) throws {
        if pin { pinned.insert(path) }
        if var pending, !pending.window.paths.contains(path) {
            guard pending.window.paths.count < HLSManifestGraph.maximumReferences else { throw HLSSourceError.graphLimit }
            let charge = try budget.reserve(bytes: 256)
            pending.window.charges.append(charge); pending.window.paths.insert(path); self.pending = pending
        }
    }
    func lease(path: String) throws -> Resource {
        guard let owner = source.context.owner else { throw HLSSourceError.unboundOwner }
        guard let resource = try source.withCurrentResolution(owner: owner, generation: source.generation, operation: {
            try lock.withLock {
                guard !retired else { throw HLSSourceError.retired }
                guard let entry = entries[path] else { throw HLSSourceError.invalidURL }
                return entry
            }
        }) else { throw HLSSourceError.staleResolution }
        return resource
    }
    func retire() { lock.withLock {
        retired = true; entries.removeAll(); reverse.removeAll(); windows.removeAll(); pending = nil; pinned.removeAll()
    } }
}
