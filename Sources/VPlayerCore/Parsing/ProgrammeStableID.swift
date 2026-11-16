// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

enum ProgrammeStableID {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func make(
        channelID: String,
        startEpochSeconds: Int64,
        stopEpochSeconds: Int64,
        title: String
    ) -> String {
        let channelUTF8 = channelID.utf8
        let titleUTF8 = title.utf8
        var encoded = Data()
        encoded.reserveCapacity(1 + 8 + channelUTF8.count + 8 + 8 + 8 + titleUTF8.count)
        encoded.append(1)

        append(UInt64(channelUTF8.count), to: &encoded)
        encoded.append(contentsOf: channelUTF8)
        append(startEpochSeconds, to: &encoded)
        append(stopEpochSeconds, to: &encoded)
        append(UInt64(titleUTF8.count), to: &encoded)
        encoded.append(contentsOf: titleUTF8)

        let digest = SHA256.hash(data: encoded)
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
