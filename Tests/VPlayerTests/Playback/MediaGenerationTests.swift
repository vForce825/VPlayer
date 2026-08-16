// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class MediaGenerationTests: XCTestCase {
    private let goldenDigest = "aa072b85a84b6bf1a5856da25e7838ab9630789444302a0bec21dc2b954b91fe"

    func testGenerationChangesOnlyForChangedFingerprintAndRejectsStaleWork() {
        var subject = GenerationController()

        XCTAssertEqual(subject.current, MediaGeneration(rawValue: 0))
        XCTAssertEqual(subject.observe(.init(bytes: Data([1]))), MediaGeneration(rawValue: 1))
        XCTAssertEqual(subject.observe(.init(bytes: Data([1]))), MediaGeneration(rawValue: 1))
        XCTAssertEqual(subject.observe(.init(bytes: Data([2]))), MediaGeneration(rawValue: 2))
        XCTAssertFalse(subject.accepts(MediaGeneration(rawValue: 1)))
        XCTAssertTrue(subject.accepts(MediaGeneration(rawValue: 2)))
    }

    func testForceAdvanceInvalidatesFingerprintAndNextObservationAdvancesAgain() {
        var subject = GenerationController()
        let fingerprint = MediaFormatFingerprint(bytes: Data([1]))

        XCTAssertEqual(subject.observe(fingerprint), MediaGeneration(rawValue: 1))
        XCTAssertEqual(subject.forceAdvance(), MediaGeneration(rawValue: 2))
        XCTAssertEqual(subject.observe(fingerprint), MediaGeneration(rawValue: 3))
    }

    func testMediaGenerationComparableRawValueContract() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(MediaGeneration.self)

        XCTAssertLessThan(MediaGeneration(rawValue: 1), MediaGeneration(rawValue: 2))
        XCTAssertEqual(Set([MediaGeneration(rawValue: 1), MediaGeneration(rawValue: 1)]).count, 1)
    }

    func testCanonicalFingerprintMatchesIndependentGoldenVector() throws {
        let fingerprint = try makeFingerprint()

        XCTAssertEqual(fingerprint.bytes.count, 32)
        XCTAssertEqual(fingerprint.bytes.hexString, goldenDigest)
        XCTAssertEqual(try makeFingerprint(), fingerprint)
    }

    func testEveryIncludedVideoAndProgramFieldChangesFingerprint() throws {
        let base = try makeFingerprint()
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let variants = [
            try makeFingerprint(programID: nil),
            try makeFingerprint(programID: 0x0102_0305),
            try makeFingerprint(video: .some(nil)),
            try makeFingerprint(video: makeVideo(streamIndex: 0x0506_0709, timeBase: timeBase)),
            try makeFingerprint(video: makeVideo(codec: .hevc, timeBase: timeBase)),
            try makeFingerprint(video: makeVideo(width: 1_921, timeBase: timeBase)),
            try makeFingerprint(video: makeVideo(height: 1_081, timeBase: timeBase)),
            try makeFingerprint(video: makeVideo(extradata: Data([1, 2, 4]), timeBase: timeBase)),
        ]

        for variant in variants {
            XCTAssertNotEqual(variant, base)
        }
    }

    func testVideoFrameRateChangesFingerprint() throws {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let twentyFive = try XCTUnwrap(MediaRational(num: 25, den: 1))
        let fifty = try XCTUnwrap(MediaRational(num: 50, den: 1))

        let base = try makeFingerprint(video: makeVideo(frameRate: twentyFive, timeBase: timeBase))
        let changed = try makeFingerprint(video: makeVideo(frameRate: fifty, timeBase: timeBase))

        XCTAssertNotEqual(base, changed)
    }

    func testEveryIncludedAudioFieldAndOptionalChangesFingerprint() throws {
        let base = try makeFingerprint()
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let variants = [
            try makeFingerprint(audio: .some(nil)),
            try makeFingerprint(audio: makeAudio(streamIndex: 10, timeBase: timeBase)),
            try makeFingerprint(audio: makeAudio(codec: .eac3, timeBase: timeBase)),
            try makeFingerprint(audio: makeAudio(sampleRate: 44_100, timeBase: timeBase)),
            try makeFingerprint(audio: makeAudio(channelCount: 6, timeBase: timeBase)),
            try makeFingerprint(audio: makeAudio(nativeMask: nil, timeBase: timeBase)),
            try makeFingerprint(audio: makeAudio(nativeMask: 4, timeBase: timeBase)),
            try makeFingerprint(audio: makeAudio(extradata: Data([0x12, 0x11]), timeBase: timeBase)),
            try makeFingerprint(cookie: nil),
            try makeFingerprint(cookie: Data([0])),
        ]

        for variant in variants {
            XCTAssertNotEqual(variant, base)
        }
    }

    func testParameterSetOrderAndLengthPrefixesAreUnambiguous() throws {
        let ordered = try makeFingerprint(parameterSets: [Data([0x67, 0x64]), Data([0x68])])
        let reversed = try makeFingerprint(parameterSets: [Data([0x68]), Data([0x67, 0x64])])
        let splitA = try makeFingerprint(parameterSets: [Data([0x01]), Data([0x02, 0x03])])
        let splitB = try makeFingerprint(parameterSets: [Data([0x01, 0x02]), Data([0x03])])

        XCTAssertNotEqual(ordered, reversed)
        XCTAssertNotEqual(splitA, splitB)
    }

    func testNilAndEmptyOptionalsHaveDifferentFingerprints() throws {
        XCTAssertNotEqual(try makeFingerprint(cookie: nil), try makeFingerprint(cookie: Data()))

        let base = try makeFingerprint()
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let emptyVideo = makeVideo(extradata: Data(), timeBase: timeBase)
        XCTAssertNotEqual(
            try makeFingerprint(video: .some(nil)),
            try makeFingerprint(video: emptyVideo)
        )
        XCTAssertNotEqual(base, try makeFingerprint(video: emptyVideo))
    }

    func testV1IntentionallyIgnoresTimeBasesAndVideoDelay() throws {
        let base = try makeFingerprint()
        let otherTimeBase = try XCTUnwrap(MediaRational(num: 1_001, den: 30_000))
        let video = makeVideo(videoDelay: 99, timeBase: otherTimeBase)
        let audio = makeAudio(timeBase: otherTimeBase)

        XCTAssertEqual(try makeFingerprint(video: video, audio: audio), base)
    }

    func testFingerprintErrorIsPublicValueContract() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(MediaFormatFingerprintError.self)

        XCTAssertEqual(
            MediaFormatFingerprintError.valueExceedsUInt32,
            MediaFormatFingerprintError.valueExceedsUInt32
        )
    }

    func testCanonicalCountRejectsOversizedValueWithoutTruncating() {
        let oversized = Int(UInt32.max) + 1

        XCTAssertThrowsError(try MediaFormatFingerprint.checkedCanonicalCount(oversized)) { error in
            XCTAssertEqual(error as? MediaFormatFingerprintError, .valueExceedsUInt32)
        }
    }

    func testPlaybackCoreErrorHasExactEquatableCases() {
        let values: [PlaybackCoreError] = [
            .unsupportedProtocol("udp"),
            .demuxOpen(-1),
            .demuxRead(-2),
            .networkTimeout,
            .unsupportedVideoCodec,
            .unsupportedAudioCodec,
            .videoFormatDescription(-3),
            .hardwareDecoderUnavailable,
            .videoDecode(-4),
            .audioFormatDescription(-5),
            .audioFallbackDecode(-6),
            .audioRendererFailed("failed"),
            .renderTextureMapping,
            .metalCommand("failed"),
            .cancelled,
        ]

        XCTAssertEqual(values.count, 15)
        XCTAssertEqual(values, values)
    }

    private func makeFingerprint(
        programID: Int32? = 0x0102_0304,
        video: VideoTrackDescriptor?? = nil,
        parameterSets: [Data] = [Data([0x67, 0x64]), Data([0x68])],
        audio: AudioTrackDescriptor?? = nil,
        cookie: Data?? = .some(Data())
    ) throws -> MediaFormatFingerprint {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let selectedVideo = video ?? .some(makeVideo(timeBase: timeBase))
        let selectedAudio = audio ?? .some(makeAudio(timeBase: timeBase))
        return try MediaFormatFingerprint(
            trackSet: DemuxTrackSet(
                selectedProgramID: programID,
                video: selectedVideo,
                audio: selectedAudio
            ),
            videoParameterSets: parameterSets,
            audioCookie: cookie ?? nil
        )
    }

    private func makeVideo(
        streamIndex: Int32 = 0x0506_0708,
        codec: VideoCodec = .h264,
        width: Int32 = 1_920,
        height: Int32 = 1_080,
        videoDelay: Int32 = 1,
        extradata: Data = Data([1, 2, 3]),
        frameRate: MediaRational? = nil,
        timeBase: MediaRational
    ) -> VideoTrackDescriptor {
        VideoTrackDescriptor(
            streamIndex: streamIndex,
            codec: codec,
            timeBase: timeBase,
            width: width,
            height: height,
            videoDelay: videoDelay,
            extradata: extradata,
            frameRate: frameRate
        )
    }

    private func makeAudio(
        streamIndex: Int32 = 9,
        codec: AudioCodec = .aac,
        sampleRate: Int32 = 48_000,
        channelCount: Int32 = 2,
        nativeMask: UInt64? = 3,
        extradata: Data = Data([0x12, 0x10]),
        timeBase: MediaRational
    ) -> AudioTrackDescriptor {
        AudioTrackDescriptor(
            streamIndex: streamIndex,
            codec: codec,
            timeBase: timeBase,
            sampleRate: sampleRate,
            channelLayout: AudioChannelLayout(
                channelCount: channelCount,
                nativeMask: nativeMask
            ),
            extradata: extradata
        )
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
