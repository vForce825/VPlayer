// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
import VideoToolbox
@testable import VPlayerPlayback

final class PlaybackErrorMappingTests: XCTestCase {
    func testPlaybackFailureInitializerRemainsSourceCompatibleAndDiagnosticDefaultsToNil() {
        let failure = PlaybackFailure(
            code: "video.decode",
            userMessage: "视频解码失败，请尝试其他频道。"
        )

        XCTAssertEqual(failure.code, "video.decode")
        XCTAssertEqual(failure.userMessage, "视频解码失败，请尝试其他频道。")
        XCTAssertNil(failure.diagnosticCode)
    }

    func testVideoDecodeMappingPreservesSignedStatusOnlyInDiagnosticCode() {
        let secret = "https://user:password@example.test/live?token=secret"
        let failure = PlaybackController.failure(for: .videoDecode(-12_909))

        XCTAssertEqual(failure.code, "video.decode")
        XCTAssertEqual(failure.userMessage, "视频解码失败，请尝试其他频道。")
        XCTAssertEqual(failure.diagnosticCode, "video.decode.status.-12909")
        XCTAssertFalse(failure.diagnosticCode?.contains(secret) == true)
    }

    func testAudioFailuresExposeOnlyBoundedMachineSafeDiagnostics() {
        XCTAssertEqual(
            PlaybackController.failure(for: .audioFallbackDecode(-12_345)).diagnosticCode,
            "audio.decode.status.-12345"
        )
        XCTAssertEqual(
            PlaybackController.failure(
                for: .audioRendererFailed("AVFoundationErrorDomain:-11847")
            ).diagnosticCode,
            "audio.renderer.reason.AVFoundationErrorDomain:-11847"
        )
        XCTAssertEqual(
            PlaybackController.failure(
                for: .audioRendererFailed("https://secret.example/live?token=do-not-export")
            ).diagnosticCode,
            "audio.renderer.reason.unknown"
        )
    }

    func testEveryCoreFailureMapsOnceToStablePublicCodeAndActionableChineseMessage() {
        let cases: [(PlaybackCoreError, String, String)] = [
            (.unsupportedProtocol("udp"), "protocol.unsupported", "不支持此播放协议，请使用 HTTP 或 HTTPS 地址。"),
            (.demuxOpen(-1), "demux.open", "无法打开频道流，请检查地址和网络后重试。"),
            (.demuxRead(-2), "demux.read", "读取频道流失败，请检查网络后重试。"),
            (.networkTimeout, "network.timeout", "连接频道超时，请检查网络后重试。"),
            (.unsupportedVideoCodec, "video.codec", "不支持此频道的视频编码，请尝试其他频道。"),
            (.unsupportedAudioCodec, "audio.codec", "不支持此频道的音频编码，请尝试其他频道。"),
            (.videoFormatDescription(-3), "video.format", "无法解析视频格式，请尝试其他频道。"),
            (.hardwareDecoderUnavailable, "video.hardware", "硬件视频解码器不可用，请稍后重试。"),
            (.videoDecode(-4), "video.decode", "视频解码失败，请尝试其他频道。"),
            (.audioFormatDescription(-5), "audio.format", "无法解析音频格式，请尝试其他频道。"),
            (.audioFallbackDecode(-6), "audio.decode", "音频解码失败，请尝试其他频道。"),
            (.audioRendererFailed("renderer"), "audio.renderer", "音频输出失败，请检查播放设备后重试。"),
            (.renderTextureMapping, "video.texture", "视频纹理处理失败，请稍后重试。"),
            (.metalCommand("command"), "metal.command", "视频渲染失败，请稍后重试。"),
            (.cancelled, "playback.cancelled", "播放已取消，请重新选择频道。"),
        ]

        for (core, code, message) in cases {
            let failure = PlaybackController.failure(for: core)
            XCTAssertEqual(failure.code, code)
            XCTAssertEqual(failure.userMessage, message)
        }
    }

    func testVideoDecoderFailuresRetainRequiredDistinctionsAtPipelineBoundary() {
        XCTAssertEqual(PlaybackPipeline.coreError(for: .sessionCreate(-7)), .videoDecode(-7))
        XCTAssertEqual(PlaybackPipeline.coreError(for: .softwareDecoder), .hardwareDecoderUnavailable)
        XCTAssertEqual(PlaybackPipeline.coreError(for: .badData(-8)), .videoDecode(-8))
        XCTAssertEqual(PlaybackPipeline.coreError(for: .malfunction(-9)), .videoDecode(-9))
        XCTAssertEqual(
            PlaybackPipeline.coreError(for: .backpressureTimeout),
            .videoDecode(kVTVideoDecoderNotAvailableNowErr)
        )
    }
}
