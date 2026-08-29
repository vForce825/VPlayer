// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class AC3AudioCodecProfileTests: XCTestCase {
    func testAC3ExactFrameLengthRejectsTrailingByte() throws {
        let source = makeSource(channels: 2, nativeMask: 3)
        let valid = AssemblerTestFixtures.syntheticAC3Frame(acmod: 2, lfeon: false)

        XCTAssertNoThrow(try AC3AudioCodecProfile().inspect(
            makeFrame(valid, channels: 2, nativeMask: 3),
            source: source
        ))
        XCTAssertThrowsError(try AC3AudioCodecProfile().inspect(
            makeFrame(valid + Data([0]), channels: 2, nativeMask: 3),
            source: source
        ))
    }

    func testAC3BuildsExactThirtyOneByteCoreMediaCookieFromHeaderFields() throws {
        let source = makeSource(channels: 6, nativeMask: 0x60F)
        let frame = AssemblerTestFixtures.syntheticAC3Frame(
            fscod: 0, frmsizecod: 20, bsid: 8, bsmod: 3, acmod: 7, lfeon: true
        )
        let inspected = try AC3AudioCodecProfile().inspect(
            makeFrame(frame, channels: 6, nativeMask: 0x60F), source: source
        )

        XCTAssertEqual(inspected.systemFormat.magicCookie, Data([
            0x00, 0x00, 0x00, 0x0C, 0x66, 0x72, 0x6D, 0x61,
            0x61, 0x63, 0x2D, 0x33,
            0x00, 0x00, 0x00, 0x0B, 0x64, 0x61, 0x63, 0x33,
            0x10, 0xFD, 0x40,
            0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00,
        ]))
        XCTAssertEqual(inspected.systemFormat.magicCookie?.count, 31)
    }

    func testAC35Point1UsesMPEG51AAndMatchesSyntheticAVAssetReaderReference() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "ac3-48k-5point1", withExtension: "mov")
        )
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let reference = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let firstSampleSize = CMSampleBufferGetSampleSize(sample, at: 0)
        let payload = Data(try copiedSampleData(sample).prefix(firstSampleSize))
        XCTAssertEqual(payload.count, 1_792)
        XCTAssertEqual(Data(payload.prefix(2)), Data([0x0B, 0x77]))
        let source = makeSource(channels: 6, nativeMask: 0x60F)
        let inspected = try AC3AudioCodecProfile().inspect(
            makeFrame(payload, channels: 6, nativeMask: 0x60F), source: source
        )

        guard case let .tag(tag, equivalentBitmap) = inspected.systemFormat.layout else {
            return XCTFail("expected canonical named 5.1 layout")
        }
        XCTAssertEqual(tag, kAudioChannelLayoutTag_MPEG_5_1_A)
        XCTAssertEqual(equivalentBitmap.rawValue, 0x3F)
        XCTAssertNotEqual(tag, kAudioChannelLayoutTag_MPEG_5_1_C)

        let built = try AudioFormatDescriptionBuilder.make(inspected.systemFormat).description
        XCTAssertTrue(CMFormatDescriptionEqualIgnoringExtensionKeys(
            built,
            otherFormatDescription: reference,
            extensionKeysToIgnore: [
                kCMFormatDescriptionExtension_VerbatimSampleDescription,
            ] as CFArray,
            sampleDescriptionExtensionAtomKeysToIgnore: nil
        ))
    }

    func testAC3StereoUsesCanonicalStereoLayout() throws {
        let source = makeSource(channels: 2, nativeMask: 3)
        let inspected = try AC3AudioCodecProfile().inspect(
            makeFrame(
                AssemblerTestFixtures.syntheticAC3Frame(acmod: 2, lfeon: false),
                channels: 2,
                nativeMask: 3
            ),
            source: source
        )

        guard case let .tag(tag, equivalentBitmap) = inspected.systemFormat.layout else {
            return XCTFail("expected canonical named stereo layout")
        }
        XCTAssertEqual(tag, kAudioChannelLayoutTag_Stereo)
        XCTAssertEqual(equivalentBitmap.rawValue, 3)
    }

    func testValidCRCFrameCanOverrideContainerCorruptFlag() throws {
        let source = makeSource(channels: 2, nativeMask: 3)
        let valid = AssemblerTestFixtures.syntheticAC3Frame(acmod: 2, lfeon: false)
        let inspected = try AC3AudioCodecProfile().inspect(
            makeFrame(valid, channels: 2, nativeMask: 3, corrupt: true),
            source: source
        )
        XCTAssertEqual(inspected.payload, valid)

        var badCRC = valid
        badCRC[badCRC.count - 1] ^= 1
        XCTAssertThrowsError(try AC3AudioCodecProfile().inspect(
            makeFrame(badCRC, channels: 2, nativeMask: 3, corrupt: true),
            source: source
        ))
        XCTAssertThrowsError(try AC3AudioCodecProfile().inspect(
            makeFrame(Data(valid.dropLast()), channels: 2, nativeMask: 3, corrupt: true),
            source: source
        ))
    }

    func testAC3SystemCookieNeverReplacesFFmpegDecoderExtradata() throws {
        let decoderExtradata = Data([0xDE, 0xC0, 0xDE])
        let source = makeSource(channels: 2, nativeMask: 3, extradata: decoderExtradata)
        let inspected = try AC3AudioCodecProfile().inspect(
            makeFrame(
                AssemblerTestFixtures.syntheticAC3Frame(acmod: 2, lfeon: false),
                channels: 2,
                nativeMask: 3
            ),
            source: source
        )
        let configuration = CompressedAudioRenderConfiguration(
            formatDescription: try AudioFormatDescriptionBuilder.make(
                inspected.systemFormat
            ).description,
            codec: source.codec,
            decoderExtradata: source.extradata,
            fingerprint: MediaFormatFingerprint(bytes: Data([0xAC, 0x03]))
        )

        XCTAssertEqual(configuration.decoderExtradata, decoderExtradata)
        XCTAssertEqual(source.extradata, decoderExtradata)
        XCTAssertNotEqual(inspected.systemFormat.magicCookie, decoderExtradata)
        XCTAssertEqual(inspected.systemFormat.magicCookie?.count, 31)
    }

    private func makeSource(
        channels: Int32,
        nativeMask: UInt64,
        extradata: Data = Data()
    ) -> AudioTrackDescriptor {
        AudioTrackDescriptor(
            streamIndex: 1,
            codec: .ac3,
            timeBase: MediaRational(num: 1, den: 48_000)!,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: channels, nativeMask: nativeMask),
            extradata: extradata
        )
    }

    private func makeFrame(
        _ payload: Data,
        channels: Int32,
        nativeMask: UInt64,
        corrupt: Bool = false
    ) -> FramedCompressedAudioFrame {
        FramedCompressedAudioFrame(
            payload: payload,
            presentationTimeStamp: .zero,
            parserSampleCount: 1_536,
            parserSampleRate: 48_000,
            parserChannelLayout: AudioChannelLayout(
                channelCount: channels,
                nativeMask: nativeMask
            ),
            containerMarkedCorrupt: corrupt
        )
    }
}
