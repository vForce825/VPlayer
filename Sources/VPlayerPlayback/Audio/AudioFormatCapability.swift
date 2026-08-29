// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation

protocol SystemAudioDecodeCapabilityChecking: Sendable {
    func supportsDecoding(formatID: AudioFormatID) -> Bool
}

final class CoreAudioDecodeCapabilityChecker:
    SystemAudioDecodeCapabilityChecking,
    @unchecked Sendable
{
    typealias InventoryLoader = @Sendable () -> Set<AudioFormatID>

    private let lock = NSLock()
    private let inventoryLoader: InventoryLoader
    private var cachedInventory: Set<AudioFormatID>?

    init(inventoryLoader: @escaping InventoryLoader = CoreAudioDecodeCapabilityChecker.loadInventory) {
        self.inventoryLoader = inventoryLoader
    }

    func supportsDecoding(formatID: AudioFormatID) -> Bool {
        lock.withLock {
            if let cachedInventory {
                return cachedInventory.contains(formatID)
            }
            let inventory = inventoryLoader()
            cachedInventory = inventory
            return inventory.contains(formatID)
        }
    }

    private static func loadInventory() -> Set<AudioFormatID> {
        var byteCount: UInt32 = 0
        guard AudioFormatGetPropertyInfo(
            kAudioFormatProperty_DecodeFormatIDs,
            0,
            nil,
            &byteCount
        ) == noErr,
        byteCount > 0,
        byteCount % UInt32(MemoryLayout<AudioFormatID>.size) == 0 else {
            return []
        }

        let count = Int(byteCount) / MemoryLayout<AudioFormatID>.size
        var formats = [AudioFormatID](repeating: 0, count: count)
        let status = formats.withUnsafeMutableBytes { buffer in
            AudioFormatGetProperty(
                kAudioFormatProperty_DecodeFormatIDs,
                0,
                nil,
                &byteCount,
                buffer.baseAddress
            )
        }
        guard status == noErr else { return [] }
        return Set(formats)
    }
}

protocol PCMOutputFormatValidating: Sendable {
    func isValidPCMOutput(_ format: CMAudioFormatDescription) -> Bool
}

struct PCMOutputFormatValidator: PCMOutputFormatValidating {
    func isValidPCMOutput(_ format: CMAudioFormatDescription) -> Bool {
        guard CMFormatDescriptionGetMediaSubType(format) == kAudioFormatLinearPCM,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate.isFinite,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0,
              asbd.mBitsPerChannel == 32,
              asbd.mFramesPerPacket == 1 else {
            return false
        }

        let (bytesPerFrame, overflow) = asbd.mChannelsPerFrame.multipliedReportingOverflow(by: 4)
        guard !overflow,
              asbd.mBytesPerFrame == bytesPerFrame,
              asbd.mBytesPerPacket == bytesPerFrame else {
            return false
        }

        let requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
            kAudioFormatFlagsNativeEndian
        return asbd.mFormatFlags & requiredFlags == requiredFlags
    }
}
