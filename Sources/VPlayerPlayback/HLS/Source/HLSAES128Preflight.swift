// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CommonCrypto
import Foundation

/// Standard identity-format, whole-segment AES-128 only. The caller reserves the
/// ciphertext-sized plaintext buffer plus IV workspace before entering this call.
/// This never modifies the manifest or proxy's original encrypted representation.
enum HLSAES128Preflight {
    static let workspaceBytes = 32 // One 16-byte IV, plus primitive output-size/alignment overhead.

    static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128,
              !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { throw HLSSourceError.unsupportedMedia }
        var plaintext = Data(count: ciphertext.count)
        var written = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, input.count,
                            output.baseAddress, output.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess, written > 0, written <= plaintext.count else {
            plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex)
            throw HLSSourceError.unsupportedMedia
        }
        plaintext.removeSubrange(written..<plaintext.count)
        return plaintext
    }
}
