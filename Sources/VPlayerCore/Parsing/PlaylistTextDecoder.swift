// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import Foundation

public enum PlaylistTextDecodingError: Error, Equatable, Sendable { case unsupportedEncoding }

public struct PlaylistTextDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]),
           let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return value }
        if data.starts(with: [0xFE, 0xFF]),
           let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return value }
        if let value = String(data: data, encoding: .utf8) { return value }
        let gb18030 = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        if let value = String(data: data, encoding: gb18030) { return value }
        if let value = String(data: data, encoding: .isoLatin1) { return value }
        throw PlaylistTextDecodingError.unsupportedEncoding
    }
}
