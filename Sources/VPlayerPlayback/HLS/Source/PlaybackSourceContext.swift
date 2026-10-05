// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum HLSSourceError: Error, Sendable, Equatable {
    case invalidURL, invalidHeader, unboundOwner, staleResolution, retired
    case network, unauthorized, deadline, byteLimit, graphLimit, redirectLimit
    case malformedManifest, unsupportedMedia, incompleteEvidence, capacity
}

public struct PlaybackSourceOrigin: Sendable, Hashable {
    public let scheme: String
    public let host: String
    public let port: Int
    public init(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= 8_192,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { throw HLSSourceError.invalidURL }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { throw HLSSourceError.invalidURL }
        self.scheme = scheme; self.host = host; self.port = port
    }
}

public struct PlaybackSourceHeaders: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let origin: PlaybackSourceOrigin
    private let values: [String: String]
    private let charge: SourceContextCharge
    fileprivate init(origin: PlaybackSourceOrigin, values: [String: String], charge: SourceContextCharge) {
        self.origin = origin; self.values = values; self.charge = charge
    }
    public var isEmpty: Bool { values.isEmpty }
    public func fields(for url: URL) -> [String: String] {
        guard (try? PlaybackSourceOrigin(url)) == origin else { return [:] }
        return values
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.origin == rhs.origin && lhs.values == rhs.values }
    public var description: String { "PlaybackSourceHeaders(redacted, count=\(values.count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": true]) }
}

/// Nonces come from the existing live control authority; this type allocates none.
public struct PlaybackSourceOwner: Sendable, Hashable {
    public let backendIdentity: PlaybackBackendIdentity
    public let prepareNonce: UInt64
    public let outputLifecycleNonce: UInt64
    public init(backendIdentity: PlaybackBackendIdentity, prepareNonce: UInt64, outputLifecycleNonce: UInt64) {
        self.backendIdentity = backendIdentity; self.prepareNonce = prepareNonce; self.outputLifecycleNonce = outputLifecycleNonce
    }
    init(ticket: PrepareTicket, lifecycle: OutputLifecycleEpoch) throws {
        guard ticket.backendIdentity == lifecycle.backendIdentity, ticket.prepareNonce != 0, lifecycle.outputNonce != 0 else {
            throw HLSSourceError.unboundOwner
        }
        self.init(backendIdentity: ticket.backendIdentity, prepareNonce: ticket.prepareNonce, outputLifecycleNonce: lifecycle.outputNonce)
    }
}

public struct PlaybackSourceContext: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let requestID: UUID
    public let sourceProfileID: UUID
    public let channelID: String
    public let entryURL: URL
    public let headers: PlaybackSourceHeaders
    public private(set) var explicitExpiry: Date?
    public private(set) var owner: PlaybackSourceOwner?
    private let charge: SourceContextCharge

    public init(requestID: UUID, sourceProfileID: UUID, channelID: String, entryURL: URL,
                attributes: [String: String] = [:], explicitExpiry: Date? = nil,
                ledger: PlaybackApplicationChargeLedger = .shared) throws {
        let charge = try SourceContextCharge(ledger: ledger)
        guard channelID.utf8.count <= 4_096, attributes.count <= 128 else { throw HLSSourceError.byteLimit }
        let origin = try PlaybackSourceOrigin(entryURL)
        let names = ["user-agent": "User-Agent", "http-user-agent": "User-Agent", "referer": "Referer",
                     "referrer": "Referer", "http-referer": "Referer", "http-referrer": "Referer", "authorization": "Authorization"]
        var fields: [String: String] = [:]
        var bytes = 0
        for (name, value) in attributes {
            guard name.utf8.count <= 256 else { throw HLSSourceError.invalidHeader }
            guard let canonical = names[name.lowercased()] else { continue }
            guard fields[canonical] == nil, value.utf8.count <= 8_192,
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw HLSSourceError.invalidHeader }
            guard value.utf8.count <= 16_384 - bytes else { throw HLSSourceError.invalidHeader }
            bytes += value.utf8.count; fields[canonical] = value
        }
        self.requestID = requestID; self.sourceProfileID = sourceProfileID; self.channelID = channelID
        self.entryURL = entryURL; self.explicitExpiry = explicitExpiry; self.owner = nil; self.charge = charge
        headers = PlaybackSourceHeaders(origin: origin, values: fields, charge: charge)
    }
    public func bound(to owner: PlaybackSourceOwner) throws -> Self {
        guard owner.backendIdentity.sessionIdentity.requestID == requestID,
              owner.prepareNonce != 0, owner.outputLifecycleNonce != 0,
              self.owner == nil || self.owner == owner else { throw HLSSourceError.unboundOwner }
        var result = self; result.owner = owner; return result
    }
    public func consumingExpiry(at date: Date) -> Self {
        guard let explicitExpiry, explicitExpiry <= date else { return self }
        var result = self; result.explicitExpiry = nil; return result
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestID == rhs.requestID && lhs.sourceProfileID == rhs.sourceProfileID && lhs.channelID == rhs.channelID &&
        lhs.entryURL == rhs.entryURL && lhs.headers == rhs.headers && lhs.explicitExpiry == rhs.explicitExpiry && lhs.owner == rhs.owner
    }
    public var description: String { "PlaybackSourceContext(transport=redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["transport": "redacted"]) }
}

/// Shared by context/header aliases; the ledger retains reservations, not this
/// separate release owner. The final real alias returns the construction charge.
fileprivate final class SourceContextCharge: @unchecked Sendable {
    private let ledger: PlaybackApplicationChargeLedger
    private let reservation: PlaybackApplicationChargeReservation
    init(ledger: PlaybackApplicationChargeLedger) throws {
        self.ledger = ledger
        do { reservation = try ledger.reserve(allocationIdentity: UUID(), bytes: HLSPreflightMemoryLimits.contextRetention) }
        catch { throw HLSSourceError.capacity }
    }
    deinit { ledger.release(reservation) }
}
