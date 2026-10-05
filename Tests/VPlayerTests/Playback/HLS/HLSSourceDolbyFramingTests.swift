// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class HLSSourceDolbyFramingTests: XCTestCase {
    func testNormalMultiSyncframePESProducesValidatedExactFrameFacts() async throws {
        for enhanced in [false, true] {
            let frame = try fixtureFrame(enhanced: enhanced)
            let samples = enhanced ? 256 : 1536
            let bytes = makeTS(enhanced: enhanced, payloads: [frame + frame + frame, frame + frame + frame],
                timestamps: [0, Int64(samples * 3 * 90_000 / 48_000)])
            let facts = try await FFmpegHLSContainerInspector().inspect(data: bytes,
                url: URL(string: "https://example.test/ordinary.ts")!, deadline: HLSMonotonicClock.deadline(seconds: 10))
            let audio = try XCTUnwrap(facts.audio.first)
            XCTAssertEqual(audio.codec, enhanced ? .eac3 : .ac3)
            XCTAssertEqual(audio.sampleRate, 48_000)
            XCTAssertEqual(audio.channelCount, 6)
            XCTAssertTrue(audio.formatValidated)
            XCTAssertEqual(audio.priming, .notSignaledPreserveTimestamps)
        }
    }

    func testLegalFrameAcrossPESKeepsFormatButDoesNotInventTimestampEvidence() async throws {
        for enhanced in [false, true] {
            let frame = try fixtureFrame(enhanced: enhanced)
            let bytes = makeTS(enhanced: enhanced,
                payloads: [Data(frame.prefix(3)), Data(frame.dropFirst(3)) + frame], timestamps: [0, 0])
            let facts = try await FFmpegHLSContainerInspector().inspect(data: bytes,
                url: URL(string: "https://example.test/ordinary.ts")!, deadline: HLSMonotonicClock.deadline(seconds: 10))
            XCTAssertEqual(facts.audio.first?.formatValidated, true)
            XCTAssertEqual(facts.audio.first?.priming, .unknown)
        }
    }

    func testIncompleteFiniteSyncframeDoesNotBecomeValidatedFacts() async throws {
        let frame = try fixtureFrame(enhanced: false)
        let bytes = makeTS(enhanced: false, payloads: [frame + frame.dropLast()], timestamps: [0])
        do {
            _ = try await FFmpegHLSContainerInspector().inspect(data: bytes,
                url: URL(string: "https://example.test/ordinary.ts")!, deadline: HLSMonotonicClock.deadline(seconds: 10))
            XCTFail("an incomplete finite syncframe was admitted")
        } catch { XCTAssertEqual(error as? HLSSourceError, .unsupportedMedia) }
    }

    private func fixtureFrame(enhanced: Bool) throws -> Data {
        let bundle = Bundle(for: Self.self)
        if enhanced {
            let url = try XCTUnwrap(bundle.url(forResource: "eac3-main-6x1block-5.1", withExtension: "eac3"))
            let bytes = try Data(contentsOf: url)
            let size = 2 * ((Int(bytes[2] & 7) << 8 | Int(bytes[3])) + 1)
            let frame = Data(bytes.prefix(size))
            XCTAssertEqual(try EAC3FrameInspector.inspect(frame).sampleCount, 256)
            return frame
        }
        let url = try XCTUnwrap(bundle.url(forResource: "ac3-48k-5point1", withExtension: "mov"))
        let bytes = try Data(contentsOf: url)
        var offset = 0
        while offset + 8 <= bytes.count {
            let size = bytes[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            guard size >= 8, size <= bytes.count-offset else { throw HLSSourceError.incompleteEvidence }
            if String(data: bytes[offset+4..<offset+8], encoding: .ascii) == "mdat" {
                // Existing pinned public fixture has 1792-byte AC-3 syncframes.
                guard size >= 8 + 1792 else { throw HLSSourceError.incompleteEvidence }
                let frame = Data(bytes[offset+8..<offset+8+1792])
                XCTAssertEqual(try AC3FrameInspector.inspect(frame).sampleCount, 1536)
                return frame
            }
            offset += size
        }
        throw HLSSourceError.incompleteEvidence
    }

    private func makeTS(enhanced: Bool, payloads: [Data], timestamps: [Int64]) -> Data {
        func section(_ bytes: [UInt8]) -> [UInt8] {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = (crc << 1) ^ (crc & 0x8000_0000 == 0 ? 0 : 0x04C1_1DB7) }
            }
            return bytes + [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
        }
        func psi(pid: UInt16, bytes: [UInt8]) -> Data {
            let payload = [UInt8(0)] + section(bytes)
            return Data([0x47, 0x40 | UInt8(pid >> 8), UInt8(truncatingIfNeeded: pid), 0x10] + payload + Array(repeating: 0xFF, count: 184-payload.count))
        }
        var result = psi(pid: 0, bytes: [0, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0])
        let registration = Array((enhanced ? "EAC3" : "AC-3").utf8)
        result += psi(pid: 0x1000, bytes: [2, 0xB0, 24, 0, 1, 0xC1, 0, 0, 0xE1, 0, 0xF0, 0, enhanced ? 0x87 : 0x81, 0xE1, 0, 0xF0, 6, 5, 4] + registration)
        var continuity: UInt8 = 0
        for (payload, pts) in zip(payloads, timestamps) {
            let size = payload.count+8
            let stamp: [UInt8] = [0x21 | UInt8((pts >> 29) & 14), UInt8((pts >> 22) & 255),
                UInt8((pts >> 14) & 254) | 1, UInt8((pts >> 7) & 255), UInt8((pts << 1) & 254) | 1]
            let pes = Data([0, 0, 1, 0xBD, UInt8(size >> 8), UInt8(size & 255), 0x80, 0x80, 5] + stamp) + payload
            var offset = 0
            while offset < pes.count {
                let count = min(184, pes.count-offset)
                var packet: [UInt8] = [0x47, offset == 0 ? 0x41 : 1, 0, (count == 184 ? 0x10 : 0x30) | continuity]
                if count < 184 {
                    let adaptation = 183-count
                    packet.append(UInt8(adaptation))
                    if adaptation > 0 { packet.append(0); packet += Array(repeating: 0xFF, count: adaptation-1) }
                }
                packet += pes[offset..<offset+count]
                result += Data(packet)
                continuity = (continuity+1)&15; offset += count
            }
        }
        return result
    }
}
