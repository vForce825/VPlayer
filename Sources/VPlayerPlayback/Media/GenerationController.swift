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
        var canonical = Data("VPlayer.MediaFormatFingerprint.v2".utf8)
        canonical.append(UInt8(0))

        canonical.appendOptional(trackSet.selectedProgramID) { data, programID in
            data.append(programID)
        }
        try canonical.appendOptional(trackSet.video) { data, video in
            data.append(video.streamIndex)
            data.append(video.codec.rawValue)
            data.append(video.width)
            data.append(video.height)
            data.appendOptional(video.frameRate) { nestedData, frameRate in
                nestedData.append(frameRate.num)
                nestedData.append(frameRate.den)
            }
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
        try canonical.appendOptional(audioSystemFormat) { data, format in
            data.append(format.profileID.rawValue)
            data.append(format.formatID)
            data.append(format.sampleRate)
            data.append(format.channelCount)
            data.append(format.framesPerPacket)
            switch format.layout {
            case let .tag(tag, equivalentBitmap):
                data.append(UInt8(0))
                data.append(tag)
                data.append(equivalentBitmap.rawValue)
            case let .bitmap(bitmap):
                data.append(UInt8(1))
                data.append(bitmap.rawValue)
            case let .discrete(count):
                data.append(UInt8(2))
                data.append(count)
            }
            try data.appendOptional(format.magicCookie) { nestedData, cookie in
                try nestedData.appendLengthPrefixed(cookie)
            }
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
