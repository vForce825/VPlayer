// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public struct AudioSystemFormatFingerprintComponent: Sendable, Hashable {
    public let profileID: AudioCodecProfileID
    public let formatID: UInt32
    public let sampleRate: Int32
    public let channelCount: Int32
    public let framesPerPacket: UInt32
    public let layout: CoreAudioLayoutSpec
    public let magicCookie: Data?

    public init(
        profileID: AudioCodecProfileID,
        formatID: UInt32,
        sampleRate: Int32,
        channelCount: Int32,
        framesPerPacket: UInt32,
        layout: CoreAudioLayoutSpec,
        magicCookie: Data?
    ) {
        self.profileID = profileID
        self.formatID = formatID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.framesPerPacket = framesPerPacket
        self.layout = layout
        self.magicCookie = magicCookie
    }
}

extension AudioSystemFormatFingerprintComponent {
    init(_ format: SystemCompressedAudioFormat) {
        self.init(
            profileID: format.profileID,
            formatID: format.formatID,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            framesPerPacket: format.framesPerPacket,
            layout: format.layout,
            magicCookie: format.magicCookie
        )
    }
}

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
        audioSystemFormat: AudioSystemFormatFingerprintComponent?
    ) throws {
        var canonical = Data()
        try Self.appendCanonical(
            to: &canonical,
            trackSet: trackSet,
            parameterSetCount: videoParameterSets.count,
            appendParameterSets: { data in
                for parameterSet in videoParameterSets {
                    try data.appendLengthPrefixed(parameterSet)
                }
            },
            audioSystemFormat: audioSystemFormat
        )
        bytes = Data(SHA256.hash(data: canonical))
    }

    init(
        trackSet: DemuxTrackSet,
        hlsVideoParameterSetOwner: HLSVideoParameterSetRetention,
        audioSystemFormat: AudioSystemFormatFingerprintComponent?
    ) throws {
        let entries = hlsVideoParameterSetOwner.entries
        let canonicalBytes = try Self.canonicalByteCount(
            trackSet: trackSet,
            parameterSetEntries: entries,
            audioSystemFormat: audioSystemFormat
        )
        bytes = try hlsVideoParameterSetOwner.withTemporaryCanonicalWorkspace(
            bytes: canonicalBytes
        ) {
            var canonical = Data()
            canonical.reserveCapacity(canonicalBytes)
            try Self.appendCanonical(
                to: &canonical,
                trackSet: trackSet,
                parameterSetCount: entries.count,
                appendParameterSets: { data in
                    for entry in entries {
                        try entry.withBytes { bytes in
                            try data.appendLengthPrefixed(bytes)
                        }
                    }
                },
                audioSystemFormat: audioSystemFormat
            )
            guard canonical.count == canonicalBytes else {
                throw MediaFormatFingerprintError.valueExceedsUInt32
            }
            return Data(SHA256.hash(data: canonical))
        }
    }

    static func checkedCanonicalCount(_ value: Int) throws -> UInt32 {
        guard let count = UInt32(exactly: value) else {
            throw MediaFormatFingerprintError.valueExceedsUInt32
        }
        return count
    }

    private static func appendCanonical(
        to canonical: inout Data,
        trackSet: DemuxTrackSet,
        parameterSetCount: Int,
        appendParameterSets: (inout Data) throws -> Void,
        audioSystemFormat: AudioSystemFormatFingerprintComponent?
    ) throws {
        canonical.append(contentsOf: "VPlayer.MediaFormatFingerprint.v2".utf8)
        canonical.append(UInt8(0))
        canonical.appendOptional(trackSet.selectedProgramID) { data, programID in data.append(programID) }
        try canonical.appendOptional(trackSet.video) { data, video in
            data.append(video.streamIndex); data.append(video.codec.rawValue)
            data.append(video.width); data.append(video.height)
            data.appendOptional(video.frameRate) { nested, frameRate in
                nested.append(frameRate.num); nested.append(frameRate.den)
            }
            try data.appendLengthPrefixed(video.extradata)
        }
        canonical.append(try checkedCanonicalCount(parameterSetCount))
        try appendParameterSets(&canonical)
        try canonical.appendOptional(trackSet.audio) { data, audio in
            data.append(audio.streamIndex); data.append(audio.codec.rawValue)
            data.append(audio.sampleRate); data.append(audio.channelLayout.channelCount)
            data.appendOptional(audio.channelLayout.nativeMask) { nested, mask in nested.append(mask) }
            try data.appendLengthPrefixed(audio.extradata)
        }
        try canonical.appendOptional(audioSystemFormat) { data, format in
            data.append(format.profileID.rawValue); data.append(format.formatID)
            data.append(format.sampleRate); data.append(format.channelCount); data.append(format.framesPerPacket)
            switch format.layout {
            case let .tag(tag, equivalentBitmap): data.append(UInt8(0)); data.append(tag); data.append(equivalentBitmap.rawValue)
            case let .bitmap(bitmap): data.append(UInt8(1)); data.append(bitmap.rawValue)
            case let .discrete(count): data.append(UInt8(2)); data.append(count)
            }
            try data.appendOptional(format.magicCookie) { nested, cookie in try nested.appendLengthPrefixed(cookie) }
        }
    }

    private static func canonicalByteCount(
        trackSet: DemuxTrackSet,
        parameterSetEntries: [HLSVideoParameterSetRetention.Entry],
        audioSystemFormat: AudioSystemFormatFingerprintComponent?
    ) throws -> Int {
        var count = "VPlayer.MediaFormatFingerprint.v2".utf8.count + 1
        func add(_ value: Int) throws { let result = count.addingReportingOverflow(value); guard !result.overflow else { throw MediaFormatFingerprintError.valueExceedsUInt32 }; count = result.partialValue }
        try add(trackSet.selectedProgramID == nil ? 1 : 5)
        if let video = trackSet.video { try add(1 + 4 + 1 + 4 + 4 + (video.frameRate == nil ? 1 : 9)); try add(4); try add(video.extradata.count) } else { try add(1) }
        try add(4)
        for entry in parameterSetEntries { try add(4); try add(entry.byteCount) }
        if let audio = trackSet.audio { try add(1 + 4 + 1 + 4 + 4 + (audio.channelLayout.nativeMask == nil ? 1 : 9) + 4); try add(audio.extradata.count) } else { try add(1) }
        guard let audioSystemFormat else { try add(1); return count }
        try add(1 + 1 + 4 + 4 + 4 + 4)
        switch audioSystemFormat.layout { case .tag: try add(1 + 4 + 4); case .bitmap, .discrete: try add(1 + 4) }
        if let cookie = audioSystemFormat.magicCookie { try add(1 + 4); try add(cookie.count) } else { try add(1) }
        return count
    }

    private static func canonicalByteCount(
        trackSet: DemuxTrackSet,
        parameterSetSizes: [Int],
        audioSystemFormat: AudioSystemFormatFingerprintComponent?
    ) throws -> Int {
        var count = "VPlayer.MediaFormatFingerprint.v2".utf8.count + 1
        func add(_ value: Int) throws {
            let result = count.addingReportingOverflow(value)
            guard !result.overflow else { throw MediaFormatFingerprintError.valueExceedsUInt32 }
            count = result.partialValue
        }
        try add(trackSet.selectedProgramID == nil ? 1 : 5)
        if let video = trackSet.video {
            try add(1 + 4 + 1 + 4 + 4 + (video.frameRate == nil ? 1 : 9))
            try add(4); try add(video.extradata.count)
        } else { try add(1) }
        try add(4)
        for size in parameterSetSizes { try add(4); try add(size) }
        if let audio = trackSet.audio {
            try add(1 + 4 + 1 + 4 + 4 + (audio.channelLayout.nativeMask == nil ? 1 : 9) + 4)
            try add(audio.extradata.count)
        } else { try add(1) }
        guard let audioSystemFormat else { try add(1); return count }
        try add(1 + 1 + 4 + 4 + 4 + 4)
        switch audioSystemFormat.layout {
        case .tag: try add(1 + 4 + 4)
        case .bitmap, .discrete: try add(1 + 4)
        }
        if let cookie = audioSystemFormat.magicCookie { try add(1 + 4); try add(cookie.count) }
        else { try add(1) }
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

    mutating func appendLengthPrefixed(_ value: borrowing Span<UInt8>) throws {
        append(try MediaFormatFingerprint.checkedCanonicalCount(value.count))
        value.withUnsafeBytes { append(contentsOf: $0) }
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
