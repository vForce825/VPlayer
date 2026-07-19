// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public enum MediaFormatFingerprintError: Error, Sendable, Equatable {
    case valueExceedsUInt32
}

public struct MediaFormatFingerprint: Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public init(
        trackSet: DemuxTrackSet,
        videoParameterSets: [Data],
        audioCookie: Data?
    ) throws {
        var canonical = Data("VPlayer.MediaFormatFingerprint.v1".utf8)
        canonical.append(UInt8(0))

        canonical.appendOptional(trackSet.selectedProgramID) { data, programID in
            data.append(programID)
        }
        try canonical.appendOptional(trackSet.video) { data, video in
            data.append(video.streamIndex)
            data.append(video.codec.rawValue)
            data.append(video.width)
            data.append(video.height)
            try data.appendLengthPrefixed(video.extradata)
        }

        canonical.append(try Self.checkedCanonicalCount(videoParameterSets.count))
        for parameterSet in videoParameterSets {
            try canonical.appendLengthPrefixed(parameterSet)
        }

        try canonical.appendOptional(trackSet.audio) { data, audio in
            data.append(audio.streamIndex)
            data.append(audio.codec.rawValue)
            data.append(audio.sampleRate)
            data.append(audio.channelLayout.channelCount)
            data.appendOptional(audio.channelLayout.nativeMask) { nestedData, mask in
                nestedData.append(mask)
            }
            try data.appendLengthPrefixed(audio.extradata)
        }
        try canonical.appendOptional(audioCookie) { data, cookie in
            try data.appendLengthPrefixed(cookie)
        }

        bytes = Data(SHA256.hash(data: canonical))
    }

    static func checkedCanonicalCount(_ value: Int) throws -> UInt32 {
        guard let count = UInt32(exactly: value) else {
            throw MediaFormatFingerprintError.valueExceedsUInt32
        }
        return count
    }
}

public struct GenerationController: Sendable {
    public private(set) var current = MediaGeneration(rawValue: 0)
    private var fingerprint: MediaFormatFingerprint?

    public init() {}

    public mutating func observe(_ newValue: MediaFormatFingerprint) -> MediaGeneration {
        guard fingerprint != newValue else { return current }
        fingerprint = newValue
        current = MediaGeneration(rawValue: current.rawValue &+ 1)
        return current
    }

    public mutating func forceAdvance() -> MediaGeneration {
        fingerprint = nil
        current = MediaGeneration(rawValue: current.rawValue &+ 1)
        return current
    }

    public func accepts(_ candidate: MediaGeneration) -> Bool {
        candidate == current
    }
}

private extension Data {
    mutating func append(_ value: Int32) {
        append(UInt32(bitPattern: value))
    }

    mutating func append(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixed(_ value: Data) throws {
        append(try MediaFormatFingerprint.checkedCanonicalCount(value.count))
        append(value)
    }

    mutating func appendOptional<Value>(
        _ value: Value?,
        appendValue: (inout Data, Value) throws -> Void
    ) rethrows {
        guard let value else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        try appendValue(&self, value)
    }
}
