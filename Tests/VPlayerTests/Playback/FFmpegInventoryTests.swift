// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class FFmpegInventoryTests: XCTestCase {
    func testLinkedFFmpegContainsExactlyTheAuditedComponents() {
        let snapshot = FFmpegInventory.snapshot()

        XCTAssertEqual(snapshot.protocols, ["crypto", "data", "http", "https", "tcp", "tls"])
        XCTAssertEqual(snapshot.demuxers, ["aac", "ac3", "eac3", "hls", "mov", "mpegts"])
        XCTAssertEqual(snapshot.parsers, ["aac", "aac_latm", "ac3", "h264", "hevc", "mpegaudio"])
        // h264 is here because interlaced H.264 has no hardware decode path on
        // Apple silicon and VideoToolbox's own software fallback manages only
        // about 20 frames a second on this hardware against a 25 fps source.
        XCTAssertEqual(snapshot.decoders, ["aac", "ac3", "eac3", "h264", "mp1", "mp2", "mp3"])

        XCTAssertFalse(snapshot.protocols.contains("udp"))
        XCTAssertFalse(snapshot.protocols.contains("rtp"))
    }

    func testInventoriesAreSortedAndContainNoDuplicates() {
        let snapshot = FFmpegInventory.snapshot()

        for names in [snapshot.protocols, snapshot.demuxers, snapshot.parsers, snapshot.decoders] {
            XCTAssertEqual(names, names.sorted())
            XCTAssertEqual(names.count, Set(names).count)
        }
    }

    func testVersionAndConfigurationIdentifyTheAuditedLGPLBuild() {
        let snapshot = FFmpegInventory.snapshot()
        let pinnedVersion = UInt32(62 << 16 | 28 << 8 | 102)

        XCTAssertEqual(snapshot.version, pinnedVersion)
        for flag in [
            "--disable-everything",
            "--disable-gpl",
            "--disable-nonfree",
            "--disable-version3",
            "--disable-shared",
            "--enable-static",
            "--disable-swscale",
            "--enable-securetransport",
            "--enable-zlib",
        ] {
            XCTAssertTrue(snapshot.configuration.contains(flag), "Missing configure gate: \(flag)")
        }
        for forbiddenFlag in ["--enable-gpl", "--enable-nonfree", "--enable-version3"] {
            XCTAssertFalse(snapshot.configuration.contains(forbiddenFlag))
        }
    }

    func testSnapshotIsSendableAndEquatable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(FFmpegComponentSnapshot.self)

        let snapshot = FFmpegInventory.snapshot()
        XCTAssertEqual(snapshot, snapshot)
    }

    func testCInventoryRejectsInvalidKindsAndOutOfBoundsIndexes() {
        let invalidKind = VPFFComponentKind(rawValue: 99)

        XCTAssertEqual(vp_ffmpeg_component_count(invalidKind), 0)
        XCTAssertNil(vp_ffmpeg_component_name(invalidKind, 0))
        XCTAssertNil(vp_ffmpeg_component_name(VPFF_COMPONENT_PROTOCOL, .max))
    }
}
