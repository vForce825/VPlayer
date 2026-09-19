// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class VideoAccessUnitBackingTests: XCTestCase {
    func testEqualLogicalIdentityAndBytesStillReceiveDistinctStrongOwnerIdentities() throws {
        let logicalIdentity = VideoAccessUnitBackingIdentity(
            generation: MediaGeneration(rawValue: 5),
            accessUnitID: 8
        )
        let bytes = Data([0, 0, 0, 1, 0x65, 0x80])

        let first = try VideoAccessUnitBacking(identity: logicalIdentity, bytes: bytes)
        let second = try VideoAccessUnitBacking(identity: logicalIdentity, bytes: bytes)

        XCTAssertEqual(first.identity, second.identity)
        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertNotEqual(first.ownerIdentity, second.ownerIdentity)
        XCTAssertFalse(first.ownerIdentity === second.ownerIdentity)
    }

    func testBackingFreezesBytesRangeIdentityAndKnownSHA256() throws {
        let generation = MediaGeneration(rawValue: 7)
        let identity = VideoAccessUnitBackingIdentity(generation: generation, accessUnitID: 19)
        var source = Data("abc".utf8)
        let backing = try VideoAccessUnitBacking(identity: identity, bytes: source)
        source[0] = 0x7A

        XCTAssertEqual(backing.identity, identity)
        XCTAssertEqual(backing.byteCount, 3)
        XCTAssertEqual(
            backing.sha256.hexString,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let wholeRange = try XCTUnwrap(VideoAccessUnitByteRange(offset: 0, length: 3))
        let frozen = try backing.withBytes(in: wholeRange) { bytes in
            bytes.withUnsafeBytes { Data($0) }
        }
        XCTAssertEqual(frozen, Data("abc".utf8))
    }

    func testByteRangeRejectsNegativeOverflowAndOutsideBacking() throws {
        XCTAssertNil(VideoAccessUnitByteRange(offset: -1, length: 1))
        XCTAssertNil(VideoAccessUnitByteRange(offset: 0, length: -1))
        XCTAssertNil(VideoAccessUnitByteRange(offset: Int.max, length: 1))

        let backing = try VideoAccessUnitBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: MediaGeneration(rawValue: 1),
                accessUnitID: 1
            ),
            bytes: Data([1, 2, 3])
        )
        let outside = try XCTUnwrap(VideoAccessUnitByteRange(offset: 2, length: 2))
        XCTAssertThrowsError(try backing.withBytes(in: outside) { _ in () }) { error in
            XCTAssertEqual(error as? VideoAccessUnitBackingError, .rangeOutsideBacking)
        }
    }

    func testVisitorReportsExactNALRangesWithoutChangingLengthPrefixedOutput() throws {
        let bytes = annexB([
            Data([0x67, 0x42]),
            Data([0x68, 0xCE]),
            Data([0x65, 0x88, 0x84]),
        ])
        let backing = try VideoAccessUnitBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: MediaGeneration(rawValue: 2),
                accessUnitID: 3
            ),
            bytes: bytes
        )
        let range = try XCTUnwrap(VideoAccessUnitByteRange(offset: 0, length: bytes.count))
        var visited: [(UInt8, VideoAccessUnitByteRange, Data, Bool, VideoRandomAccessKind)] = []

        try AnnexBScanner.visitNALUnits(in: backing, range: range, codec: .h264) { view, nal in
            visited.append((
                view.nalUnitType,
                view.byteRange,
                nal.withUnsafeBytes { Data($0) },
                view.isParameterSet,
                view.randomAccessKind
            ))
        }

        XCTAssertEqual(visited.map(\.0), [7, 8, 5])
        XCTAssertEqual(visited.map(\.2), [
            Data([0x67, 0x42]),
            Data([0x68, 0xCE]),
            Data([0x65, 0x88, 0x84]),
        ])
        XCTAssertEqual(visited.map(\.3), [true, true, false])
        XCTAssertEqual(visited.map(\.4), [.none, .none, .h264IDR])
        XCTAssertEqual(visited.map(\.1), [
            VideoAccessUnitByteRange(offset: 4, length: 2),
            VideoAccessUnitByteRange(offset: 10, length: 2),
            VideoAccessUnitByteRange(offset: 16, length: 3),
        ])

        let scan = try AnnexBScanner.scan(bytes, codec: .h264)
        XCTAssertEqual(scan.lengthPrefixedData, Data([
            0, 0, 0, 2, 0x67, 0x42,
            0, 0, 0, 2, 0x68, 0xCE,
            0, 0, 0, 3, 0x65, 0x88, 0x84,
        ]))
    }

    func testScannerRejectsParameterSetCountAndByteLimits() throws {
        let excessiveCount = annexB(Array(
            repeating: Data([0x68, 0xCE]),
            count: AnnexBScanner.maximumParameterSetCount + 1
        ))
        XCTAssertThrowsError(try AnnexBScanner.scan(excessiveCount, codec: .h264))

        var excessiveBytes = Data([0x67])
        excessiveBytes.append(Data(
            repeating: 0x55,
            count: AnnexBScanner.maximumParameterSetBytes
        ))
        XCTAssertThrowsError(try AnnexBScanner.scan(annexB([excessiveBytes]), codec: .h264))
    }

    func testBackingRejectsOversizedAccessUnitBeforeHashing() throws {
        let excessiveByteCount = AnnexBScanner.maximumAccessUnitBytes + 1
        let bytes = Data(repeating: 0, count: excessiveByteCount)

        XCTAssertThrowsError(try VideoAccessUnitBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: MediaGeneration(rawValue: 4),
                accessUnitID: 12
            ),
            bytes: bytes
        )) { error in
            XCTAssertEqual(
                error as? VideoAccessUnitBackingError,
                .accessUnitTooLarge(
                    byteCount: excessiveByteCount,
                    maximumByteCount: AnnexBScanner.maximumAccessUnitBytes
                )
            )
        }
    }

    func testAssemblerPublishesOriginalAnnexBBackingAndDigestWithAccessUnit() throws {
        let frameBytes = AssemblerTestFixtures.h264AccessUnit()
        let factory = ScriptedFFmpegParserFactory()
        let tracks = try AssemblerTestFixtures.videoTracks()
        var events: [VideoAssemblerEvent] = []
        let assembler = try CompressedVideoAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 9) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try assembler.push(AssemblerTestFixtures.videoPacket())
        try XCTUnwrap(factory.handles.first).emit(
            AssemblerTestFixtures.parsedVideoFrame(bytes: frameBytes)
        )

        let accessUnit = try XCTUnwrap(events.compactMap { event -> CompressedVideoAccessUnit? in
            guard case let .accessUnit(value) = event else { return nil }
            return value
        }.first)
        let backing = try XCTUnwrap(accessUnit.sourceBacking)
        let range = try XCTUnwrap(accessUnit.sourceByteRange)
        XCTAssertEqual(backing.identity.generation, MediaGeneration(rawValue: 9))
        XCTAssertEqual(backing.identity.accessUnitID, accessUnit.id)
        XCTAssertEqual(accessUnit.sourceSHA256, backing.sha256)
        XCTAssertEqual(range, VideoAccessUnitByteRange(offset: 0, length: frameBytes.count))
        XCTAssertEqual(
            try backing.withBytes(in: range) { bytes in
                bytes.withUnsafeBytes { Data($0) }
            },
            frameBytes
        )
    }

    private func annexB(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(unit)
        }
        return result
    }
}
