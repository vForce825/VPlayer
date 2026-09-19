// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import zlib

enum HLSPlaylistKind: Sendable { case master, media }
enum HLSAudioCodec: String, Sendable {
    case aac, ac3, eac3
    var groupPrefix: String { self == .eac3 ? "ec3" : rawValue }
    var codecs: String { switch self { case .aac: "mp4a.40.2"; case .ac3: "ac-3"; case .eac3: "ec-3" } }
}
struct HLSAudioDeclaration: Sendable, Hashable {
    var participantID: UInt64
    var renditionID: String
    var codec: HLSAudioCodec
    var channels: Int
    var language: String?
    var score: UInt64
    var peakEnvelope: UInt64
    var groupID: String { "\(codec.groupPrefix)-\(channels)" }
}
struct HLSVideoDeclaration: Sendable, Hashable {
    var participantID: UInt64
    var codec: String
    var width: Int
    var height: Int
    var frameRateMilli: UInt64
    var videoRange: String
    var peakEnvelope: UInt64
}
struct HLSItemDeclaration: Sendable, Hashable {
    var itemGeneration: UInt64
    var token: String
    var video: HLSVideoDeclaration?
    var audio: [HLSAudioDeclaration]
    func playlistURI(participantID: UInt64) throws -> String {
        let base = "/v1/\(token)/\(itemGeneration)"
        if video?.participantID == participantID { return base + "/video/index.m3u8" }
        guard let rendition = audio.first(where: { $0.participantID == participantID }) else {
            throw HLSPublicationFailure.identityMismatch
        }
        return base + "/audio/\(rendition.renditionID)/index.m3u8"
    }
    func resourceURI(_ key: HLSResourceKey) throws -> String {
        let playlist = try playlistURI(participantID: key.participantID)
        let base = "/v1/\(token)/\(itemGeneration)/"
        let trackPath = playlist.dropFirst(base.count).dropLast("index.m3u8".count)
        let authentication = key.authentication.isEmpty ? "" : "?p=\(key.participantID)&a=\(key.authentication)"
        return "/v1/\(token)/\(key.itemGeneration)/\(key.mediaEpoch)/" + trackPath
            + (key.kind == .initialization ? "init.mp4" : "\(key.logicalSequence).m4s") + authentication
    }
}

struct HLSPlaylistRepresentation: Sendable {
    let raw: Data
    let gzip: Data
    var text: String { String(decoding: raw, as: UTF8.self) }
    var residentBytes: Int { raw.count + gzip.count }
}

struct HLSBandwidthSample: Sendable {
    let bodyBytes: UInt64
    let duration: ExactMediaTime
}
struct HLSBandwidthMeasurement: Sendable, Equatable {
    let peak: UInt64
    let average: UInt64
}
enum HLSBandwidth {
    static func measure(_ samples: [HLSBandwidthSample]) throws -> HLSBandwidthMeasurement {
        guard !samples.isEmpty, samples.count <= 7 else { throw HLSPublicationFailure.invalidDuration }
        var peak: UInt64 = 0
        var totalBytes: UInt64 = 0
        var totalDuration = HLSChecked.zero
        for sample in samples {
            guard sample.duration.value > 0 else { throw HLSPublicationFailure.invalidDuration }
            totalBytes = try HLSChecked.add(totalBytes, sample.bodyBytes)
            totalDuration = try totalDuration.adding(sample.duration)
        }
        for start in samples.indices {
            var bytes: UInt64 = 0
            var duration = HLSChecked.zero
            for sample in samples[start...] {
                bytes = try HLSChecked.add(bytes, sample.bodyBytes)
                duration = try duration.adding(sample.duration)
                if try HLSChecked.compare(duration, .init(value: 3, timescale: 1)) > 0 { break }
                if try HLSChecked.compare(duration, HLSChecked.one) >= 0 {
                    peak = max(peak, try rate(bytes: bytes, duration: duration))
                }
            }
        }
        return .init(peak: peak, average: try rate(bytes: totalBytes, duration: totalDuration))
    }
    static func variant(video: [HLSBandwidthSample], audioGroup: [[HLSBandwidthSample]]) throws -> HLSBandwidthMeasurement {
        let v = try measure(video)
        let audio = try audioGroup.map(measure)
        guard !audio.isEmpty else { throw HLSPublicationFailure.invalidPlaylist }
        return .init(peak: try HLSChecked.add(v.peak, audio.map(\.peak).max()!),
            average: try HLSChecked.add(v.average, audio.map(\.average).max()!))
    }
    static func withinLiveAverage(measured: UInt64, declared: UInt64) throws -> Bool {
        try HLSChecked.multiply(measured, 10) < HLSChecked.multiply(declared, 11)
    }
    private static func rate(bytes: UInt64, duration: ExactMediaTime) throws -> UInt64 {
        let numerator = try HLSChecked.multiply(HLSChecked.multiply(bytes, 8), UInt64(duration.timescale))
        let denominator = UInt64(duration.value)
        return try HLSChecked.add(numerator / denominator, numerator % denominator == 0 ? 0 : 1)
    }
}

enum HLSPlaylistSerializer {
    private static let header = "#EXTM3U\n#EXT-X-VERSION:10\n"
    static func master(_ declaration: HLSItemDeclaration) throws -> HLSPlaylistRepresentation? {
        try validate(declaration)
        guard let video = declaration.video else { return nil }
        let audio = declaration.audio.sorted { $0.score > $1.score }
        var text = header + "#EXT-X-INDEPENDENT-SEGMENTS\n"
        for track in audio {
            text += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(track.groupID)\",NAME=\"\(track.renditionID)-main\",URI=\"\(try declaration.playlistURI(participantID: track.participantID))\",CHANNELS=\"\(track.channels)\",LANGUAGE=\"\(track.language ?? "und")\",DEFAULT=YES,AUTOSELECT=YES\n"
        }
        for track in audio {
            let bandwidth = try HLSChecked.add(video.peakEnvelope, track.peakEnvelope)
            text += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(bandwidth),RESOLUTION=\(video.width)x\(video.height),FRAME-RATE=\(decimal(video.frameRateMilli, digits: 3)),VIDEO-RANGE=\(video.videoRange),CODECS=\"\(video.codec),\(track.codec.codecs)\",AUDIO=\"\(track.groupID)\",SCORE=\(track.score)\n"
            text += try declaration.playlistURI(participantID: video.participantID) + "\n"
        }
        return try representation(raw: Data(text.utf8), kind: .master)
    }

    static func media(segments: [HLSValidatedSegment], declaration: HLSItemDeclaration,
                      discontinuitySequence: UInt64, anchor: HLSProgramDateAnchor, endList: Bool) throws -> HLSPlaylistRepresentation {
        guard (1...7).contains(segments.count), let first = segments.first else { throw HLSPublicationFailure.invalidPlaylist }
        var targetDuration = 2
        for segment in segments {
            let dur = segment.receipt.presentationRange.duration
            if dur.timescale > 0 {
                let ceiling = Int((dur.value + Int64(dur.timescale) - 1) / Int64(dur.timescale))
                if ceiling > targetDuration {
                    targetDuration = ceiling
                }
            }
        }
        var text = header + "#EXT-X-TARGETDURATION:\(targetDuration)\n#EXT-X-MEDIA-SEQUENCE:\(first.receipt.logicalSequence)\n#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)\n"
        var previousMap: HLSResourceKey?
        for segment in segments {
            if segment.discontinuity { text += "#EXT-X-DISCONTINUITY\n" }
            if previousMap != segment.initializationKey {
                text += "#EXT-X-MAP:URI=\"\(try declaration.resourceURI(segment.initializationKey))\"\n"
                previousMap = segment.initializationKey
            }
            text += "#EXT-X-PROGRAM-DATE-TIME:\(try pdt(segment.commonStart, anchor: anchor))\n"
            text += "#EXTINF:\(try duration(segment.receipt.presentationRange.duration)),\n"
            text += try declaration.resourceURI(segment.key) + "\n"
        }
        if endList { text += "#EXT-X-ENDLIST\n" }
        return try representation(raw: Data(text.utf8), kind: .media)
    }

    static func validate(_ declaration: HLSItemDeclaration) throws {
        guard declaration.itemGeneration > 0, declaration.token.utf8.count == 32,
              declaration.token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...3).contains(declaration.audio.count) else { throw HLSPublicationFailure.invalidPlaylist }
        var participants = Set<UInt64>(), groups = Set<String>(), scores = Set<UInt64>(), renditionIDs = Set<String>()
        for audio in declaration.audio {
            try identifier(audio.renditionID)
            try identifier(audio.language ?? "und")
            guard (1...8).contains(audio.channels), audio.peakEnvelope > 0, audio.score > 0,
                  participants.insert(audio.participantID).inserted,
                  groups.insert(audio.groupID).inserted, scores.insert(audio.score).inserted,
                  renditionIDs.insert(audio.renditionID).inserted else {
                throw HLSPublicationFailure.invalidPlaylist
            }
        }
        if let video = declaration.video {
            try identifier(video.codec)
            guard video.width > 0, video.height > 0, video.frameRateMilli > 0, video.frameRateMilli <= 60_000,
                  ["SDR", "PQ", "HLG"].contains(video.videoRange), video.peakEnvelope > 0,
                  participants.insert(video.participantID).inserted else { throw HLSPublicationFailure.invalidPlaylist }
        }
    }
    static func validateAudioReferences(_ references: [String], groups: Set<String>) throws {
        guard references.allSatisfy(groups.contains) else { throw HLSPublicationFailure.invalidPlaylist }
    }
    private static func identifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, value.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 95].contains(byte)
        }) else { throw HLSPublicationFailure.invalidPlaylist }
    }
    static func validateRepresentationSizes(kind: HLSPlaylistKind, raw: Int, gzip: Int) throws {
        let rawCap = kind == .media ? 262_144 : 65_536
        let combinedCap = kind == .media ? 532_480 : 135_168
        guard raw >= 0, gzip >= 0, raw <= rawCap,
              try HLSChecked.add(raw, gzip) <= combinedCap else { throw HLSPublicationFailure.capacityExceeded }
    }
    static func representation(raw: Data, kind: HLSPlaylistKind) throws -> HLSPlaylistRepresentation {
        try validateRepresentationSizes(kind: kind, raw: raw.count, gzip: 0)
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw HLSPublicationFailure.invalidPlaylist
        }
        defer { deflateEnd(&stream) }
        // gzip 默认头的 mtime 为零；固定 zlib 参数保证同一冻结输入逐字一致。
        var gzip = Data(count: Int(deflateBound(&stream, UInt(raw.count))))
        let capacity = gzip.count
        let status = raw.withUnsafeBytes { input in gzip.withUnsafeMutableBytes { output in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(raw.count)
            stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
            stream.avail_out = UInt32(capacity)
            return deflate(&stream, Z_FINISH)
        } }
        guard status == Z_STREAM_END else { throw HLSPublicationFailure.invalidPlaylist }
        gzip.count = Int(stream.total_out)
        try validateRepresentationSizes(kind: kind, raw: raw.count, gzip: gzip.count)
        return .init(raw: raw, gzip: gzip)
    }
    private static func decimal(_ value: UInt64, digits: Int) -> String {
        let scale: UInt64 = digits == 3 ? 1000 : 1_000_000_000
        let fraction = String(value % scale)
        return "\(value / scale)." + String(repeating: "0", count: digits - fraction.count) + fraction
    }
    private static func duration(_ time: ExactMediaTime) throws -> String {
        guard time.value > 0 else { throw HLSPublicationFailure.invalidDuration }
        let value = try HLSChecked.multiply(UInt64(time.value), 1_000_000_000)
        return decimal(value / UInt64(time.timescale), digits: 9)
    }
    private static func pdt(_ time: ExactMediaTime, anchor: HLSProgramDateAnchor) throws -> String {
        let offset = try time.subtracting(anchor.mediaOrigin)
        let milliseconds = try HLSChecked.add(anchor.utcMilliseconds,
            HLSChecked.multiply(offset.value, 1000) / Int64(offset.timescale))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}
