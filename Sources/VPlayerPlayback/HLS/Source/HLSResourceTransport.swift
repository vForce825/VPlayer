// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum HLSMonotonicClock {
    public static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    public static func deadline(seconds: UInt64) -> UInt64 {
        let delta = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let sum = now.addingReportingOverflow(delta.partialValue)
        return delta.overflow || sum.overflow ? UInt64.max : sum.partialValue
    }
}
public struct HLSByteRange: Sendable, Hashable {
    public let offset: Int64, length: Int64
    public init(offset: Int64, length: Int64) { self.offset = offset; self.length = length }
}
public enum HLSMediaCompleteness: Sendable, Equatable { case complete, prefix }
public enum HLSResourceCompleteness: Sendable, Equatable { case complete, prefix, byteRange }
public struct HLSHTTPContentRange: Sendable, Equatable {
    public let start: Int64, end: Int64
    public let total: Int64?
    public var length: Int64 { end - start + 1 }
    public init?(start: Int64, end: Int64, total: Int64?) {
        guard start >= 0, end >= start, end < Int64.max, total == nil || total! > end else { return nil }
        self.start = start; self.end = end; self.total = total
    }
    public init?(_ text: String) {
        guard text.utf8.count <= 128, text.hasPrefix("bytes ") else { return nil }
        let parts = text.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              parts[1] == "*" || Int64(parts[1]) != nil else { return nil }
        self.init(start: start, end: end, total: parts[1] == "*" ? nil : Int64(parts[1]))
    }
}
public struct HLSResourceRequest: Sendable, CustomStringConvertible, CustomReflectable {
    public enum Mode: Sendable, Equatable { case complete, mediaPrefix, classify }
    public let url: URL
    public let headers: PlaybackSourceHeaders
    public let range: HLSByteRange?
    public let maximumBytes: Int
    public let deadline: UInt64
    public let mode: Mode
    public init(url: URL, headers: PlaybackSourceHeaders, range: HLSByteRange? = nil, maximumBytes: Int,
                deadline: UInt64, mode: Mode = .complete) {
        self.url = url; self.headers = headers; self.range = range; self.maximumBytes = maximumBytes; self.deadline = deadline; self.mode = mode
    }
    public var description: String { "HLSResourceRequest(transport=redacted, maximumBytes=\(maximumBytes))" }
    public var customMirror: Mirror { Mirror(self, children: ["transport": "redacted"]) }
}
public struct HLSResourceResponse: Sendable, CustomStringConvertible, CustomReflectable {
    public let responseURL: URL
    public let data: Data
    public let statusCode: Int
    public let contentType: String?
    public let completeness: HLSResourceCompleteness
    public let contentRange: HLSHTTPContentRange?
    public init(responseURL: URL, data: Data, statusCode: Int = 200, contentType: String? = nil,
                completeness: HLSResourceCompleteness = .complete, contentRange: HLSHTTPContentRange? = nil) {
        self.responseURL = responseURL; self.data = data; self.statusCode = statusCode; self.contentType = contentType
        self.completeness = completeness; self.contentRange = contentRange
    }
    public var description: String { "HLSResourceResponse(status=\(statusCode), bytes=\(data.count), transport=redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["status": statusCode, "bytes": data.count]) }
}
public protocol HLSResourceTransport: Sendable {
    func fetch(_ request: HLSResourceRequest) async throws -> HLSResourceResponse
}
