// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class AudioFormatCapabilityTests: XCTestCase {
    func testCapabilityContractsAreSendable() {
        let decodeChecker: any SystemAudioDecodeCapabilityChecking =
            CoreAudioDecodeCapabilityChecker(inventoryLoader: { [] })
        let pcmValidator: any PCMOutputFormatValidating = PCMOutputFormatValidator()

        requireSendable(decodeChecker)
        requireSendable(pcmValidator)
    }

    func testCheckerUsesOnlyInjectedDecodeFormatIDs() {
        let checker = CoreAudioDecodeCapabilityChecker(
            inventoryLoader: { [kAudioFormatMPEG4AAC, kAudioFormatAC3] }
        )

        XCTAssertTrue(checker.supportsDecoding(formatID: kAudioFormatMPEG4AAC))
        XCTAssertTrue(checker.supportsDecoding(formatID: kAudioFormatAC3))
        XCTAssertFalse(checker.supportsDecoding(formatID: kAudioFormatEnhancedAC3))
        XCTAssertFalse(checker.supportsDecoding(formatID: kAudioFormatLinearPCM))
    }

    func testCheckerCachesTheInstalledDecoderInventory() {
        let loadCount = LockedAudioCapabilityLoadCount()
        let checker = CoreAudioDecodeCapabilityChecker {
            loadCount.increment()
            return [kAudioFormatMPEG4AAC]
        }

        XCTAssertTrue(checker.supportsDecoding(formatID: kAudioFormatMPEG4AAC))
        XCTAssertFalse(checker.supportsDecoding(formatID: kAudioFormatAC3))
        XCTAssertTrue(checker.supportsDecoding(formatID: kAudioFormatMPEG4AAC))
        XCTAssertEqual(loadCount.value, 1)
    }

    func testPCMValidatorRejectsMalformedLinearPCMDescription() throws {
        let validator = PCMOutputFormatValidator()

        XCTAssertTrue(validator.isValidPCMOutput(try makePCMFormat(bits: 32, bytesPerFrame: 8)))
        XCTAssertFalse(validator.isValidPCMOutput(try makePCMFormat(bits: 16, bytesPerFrame: 4)))
    }

    private func makePCMFormat(
        bits: UInt32,
        bytesPerFrame: UInt32
    ) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: 2,
            mBitsPerChannel: bits,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }
}

private func requireSendable(_ value: some Sendable) {
    _ = value
}

private final class LockedAudioCapabilityLoadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
