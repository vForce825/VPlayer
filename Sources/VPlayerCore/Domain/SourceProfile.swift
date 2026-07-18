// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum SourceProfileURLField: Equatable, Sendable { case m3u, epg }

public enum SourceProfileValidationError: Error, Equatable, Sendable {
    case emptyName
    case invalidURL(field: SourceProfileURLField)
    case unsupportedURL(field: SourceProfileURLField)
}

public struct ValidatedSourceProfileInput: Equatable, Sendable {
    public let name: String
    public let m3uURL: URL
    public let epgURL: URL
    public let m3uRefreshInterval: RefreshInterval
    public let epgRefreshInterval: RefreshInterval
}

public struct SourceProfileInput: Equatable, Sendable {
    public var name: String
    public var m3uURLString: String
    public var epgURLString: String
    public var m3uRefreshInterval: RefreshInterval
    public var epgRefreshInterval: RefreshInterval

    public init(
        name: String,
        m3uURLString: String,
        epgURLString: String,
        m3uRefreshInterval: RefreshInterval,
        epgRefreshInterval: RefreshInterval
    ) {
        self.name = name
        self.m3uURLString = m3uURLString
        self.epgURLString = epgURLString
        self.m3uRefreshInterval = m3uRefreshInterval
        self.epgRefreshInterval = epgRefreshInterval
    }

    public func validated() throws -> ValidatedSourceProfileInput {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SourceProfileValidationError.emptyName }
        let m3uURL = try Self.remoteURL(m3uURLString, field: .m3u)
        let epgURL = try Self.remoteURL(epgURLString, field: .epg)
        return ValidatedSourceProfileInput(
            name: trimmedName,
            m3uURL: m3uURL,
            epgURL: epgURL,
            m3uRefreshInterval: m3uRefreshInterval,
            epgRefreshInterval: epgRefreshInterval
        )
    }

    private static func remoteURL(_ value: String, field: SourceProfileURLField) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SourceProfileValidationError.invalidURL(field: field)
        }
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw SourceProfileValidationError.invalidURL(field: field)
        }
        guard ["http", "https"].contains(scheme) else {
            throw SourceProfileValidationError.unsupportedURL(field: field)
        }
        guard url.host != nil else {
            throw SourceProfileValidationError.invalidURL(field: field)
        }
        return url
    }
}

public struct SourceProfile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var m3uURL: URL
    public var epgURL: URL
    public var m3uRefreshInterval: RefreshInterval
    public var epgRefreshInterval: RefreshInterval
    public var m3uStatus: ResourceRefreshStatus
    public var epgStatus: ResourceRefreshStatus
    public var createdAt: Date
    public var updatedAt: Date
}
