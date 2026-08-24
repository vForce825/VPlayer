// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

enum ProgrammeStableID {
    static func make(
        channelID: String,
        startEpochSeconds: Int64,
        stopEpochSeconds: Int64,
        title: String
    ) -> String {
        let channelBytes = Data(channelID.utf8)
        let titleBytes = Data(title.utf8)
        var encoded = Data([1])

        append(UInt64(channelBytes.count), to: &encoded)
        encoded.append(channelBytes)
        append(startEpochSeconds, to: &encoded)
        append(stopEpochSeconds, to: &encoded)
        append(UInt64(titleBytes.count), to: &encoded)
        encoded.append(titleBytes)

        return SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
