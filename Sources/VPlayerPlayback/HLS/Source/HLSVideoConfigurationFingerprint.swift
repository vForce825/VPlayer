// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

/// Canonical configuration identity only. Parsing/format/scan admission remains
/// separate; hashing a header never grants a decoder, route or writer capability.
public enum HLSVideoConfigurationFingerprint {
    public static let maximumParameterSets = 64
    public static let maximumBytes = 256 * 1_024
    public static func make(codec: VideoCodec, parameterSets: [Data]) throws -> Data {
        guard !parameterSets.isEmpty, parameterSets.count <= maximumParameterSets else { throw HLSSourceError.byteLimit }
        var bytes = 0
        var canonical: [(UInt8, Data)] = []
        for data in parameterSets {
            guard data.count >= (codec == .h264 ? 2 : 3), data.count <= maximumBytes - bytes,
                  data[0] & 0x80 == 0 else { throw HLSSourceError.incompleteEvidence }
            bytes += data.count
            let kind = codec == .h264 ? data[0] & 31 : (data[0] >> 1) & 63
            guard (codec == .h264 ? [7, 8] : [32, 33, 34]).contains(Int(kind)),
                  codec == .h264 || data[1] & 7 != 0 else { throw HLSSourceError.incompleteEvidence }
            if !canonical.contains(where: { $0.0 == kind && $0.1 == data }) { canonical.append((kind, data)) }
        }
        let kinds = Set(canonical.map(\.0))
        guard kinds == (codec == .h264 ? Set<UInt8>([7, 8]) : Set<UInt8>([32, 33, 34])) else { throw HLSSourceError.incompleteEvidence }
        canonical.sort { $0.0 == $1.0 ? $0.1.lexicographicallyPrecedes($1.1) : $0.0 < $1.0 }
        var hash = SHA256()
        hash.update(data: Data("VPlayer source parameter sets v1".utf8))
        hash.update(data: Data([codec.rawValue]))
        for (_, data) in canonical {
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: data)
        }
        return Data(hash.finalize())
    }
}
