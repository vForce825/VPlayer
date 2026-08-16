// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class MediaCodecTests: XCTestCase {
    func testCodecRawValuesAreStable() {
        XCTAssertEqual(VideoCodec.h264.rawValue, 1)
        XCTAssertEqual(VideoCodec.hevc.rawValue, 2)
        XCTAssertEqual(AudioCodec.aac.rawValue, 1)
        XCTAssertEqual(AudioCodec.ac3.rawValue, 2)
        XCTAssertEqual(AudioCodec.eac3.rawValue, 3)
        XCTAssertEqual(AudioCodec.mp2.rawValue, 4)

        XCTAssertEqual(MediaCodec.video(.h264), .video(.h264))
        XCTAssertEqual(MediaCodec.audio(.eac3), .audio(.eac3))
    }

    func testTrackSetRepresentsVideoOnlyAudioOnlyDualTrackAndNilProgram() throws {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let video = VideoTrackDescriptor(
            streamIndex: 2,
            codec: .h264,
            timeBase: timeBase,
            width: 1_920,
            height: 1_080,
            videoDelay: 1,
            extradata: Data([0x01, 0x64])
        )
        let audio = AudioTrackDescriptor(
            streamIndex: 3,
            codec: .aac,
            timeBase: timeBase,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
            extradata: Data([0x12, 0x10])
        )

        let videoOnly = DemuxTrackSet(selectedProgramID: nil, video: video, audio: nil)
        let audioOnly = DemuxTrackSet(selectedProgramID: 7, video: nil, audio: audio)
        let dual = DemuxTrackSet(selectedProgramID: 7, video: video, audio: audio)

        XCTAssertNil(videoOnly.selectedProgramID)
        XCTAssertEqual(videoOnly.video, video)
        XCTAssertNil(videoOnly.audio)
        XCTAssertNil(audioOnly.video)
        XCTAssertEqual(audioOnly.audio, audio)
        XCTAssertEqual(dual.video, video)
        XCTAssertEqual(dual.audio, audio)
    }

    func testUnknownCustomLayoutDiffersFromKnownZeroMask() {
        let custom = AudioChannelLayout(channelCount: 2, nativeMask: nil)
        let knownZero = AudioChannelLayout(channelCount: 2, nativeMask: 0)

        XCTAssertNotEqual(custom, knownZero)
        XCTAssertEqual(Set([custom, custom, knownZero]).count, 2)
    }

    func testVideoFrameRateParticipatesInTrackEqualityAndHashing() throws {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let twentyFive = try XCTUnwrap(MediaRational(num: 25, den: 1))
        let fifty = try XCTUnwrap(MediaRational(num: 50, den: 1))
        let base = VideoTrackDescriptor(
            streamIndex: 2,
            codec: .h264,
            timeBase: timeBase,
            width: 1_920,
            height: 1_080,
            videoDelay: 1,
            extradata: Data([0x01, 0x64]),
            frameRate: twentyFive
        )
        let changed = VideoTrackDescriptor(
            streamIndex: 2,
            codec: .h264,
            timeBase: timeBase,
            width: 1_920,
            height: 1_080,
            videoDelay: 1,
            extradata: Data([0x01, 0x64]),
            frameRate: fifty
        )

        XCTAssertNotEqual(base, changed)
        XCTAssertEqual(Set([base, changed]).count, 2)
    }

    func testCodecAndTrackValuesAreHashableAndSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}

        requireSendable(VideoCodec.self)
        requireSendable(AudioCodec.self)
        requireSendable(MediaCodec.self)
        requireSendable(AudioChannelLayout.self)
        requireSendable(VideoTrackDescriptor.self)
        requireSendable(AudioTrackDescriptor.self)
        requireSendable(DemuxTrackSet.self)

        XCTAssertEqual(Set([MediaCodec.video(.h264), .video(.h264), .audio(.aac)]).count, 2)
    }
}
