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
