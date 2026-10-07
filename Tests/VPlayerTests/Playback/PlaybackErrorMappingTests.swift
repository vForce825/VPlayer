// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import VideoToolbox
import VPlayerCore
import XCTest
@testable import VPlayerPlayback

final class PlaybackErrorMappingTests: XCTestCase {
    func testInterlacedWriterCauseSurvivesRuntimeSnapshotAndPresentation() {
        let causes: [(any Error, String)] = [
            (SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded,
             "writer.terminalOwnershipCapacityExceeded"),
            (SegmentedFMP4WriterFailure.sourceFormatMismatch, "writer.sourceFormatMismatch"),
            (SegmentedFMP4WriterFailure.boundaryMismatch, "writer.boundaryMismatch"),
            (SegmentedFMP4WriterFailure.systemFailure, "writer.systemFailure"),
            (SegmentBoundaryFailure.ticketMismatch, "boundary.ticketMismatch"),
            (CancellationError(), "CancellationError"),
        ]
        for (cause, expected) in causes {
            // A synthetic timescale: the device's redacted diagnostic did not preserve its units.
            let message = HLSInterlacedOutputDiagnostic.message(
                stage: "writerAppend", error: cause,
                pts: CMTime(value: 29_786_400, timescale: 180_000),
                expectedVideoStart: CMTime(value: 10, timescale: 1),
                context: String(repeating: "duration=3600@180000 lastPTS=29782800@180000 ", count: 30))
            let snapshot = PlaybackErrorDiagnostics.snapshot(PlaybackCoreError.videoSampleBuffer(message))
            let failure = PlaybackController.failure(for:
                .capture(snapshot, stage: "hls.mediaGraph.runtime"))

            XCTAssertTrue(failure.userMessage.contains("stage=writerAppend"), failure.userMessage)
            XCTAssertTrue(failure.userMessage.contains("underlying=\(expected)"), failure.userMessage)
            XCTAssertTrue(failure.userMessage.contains("pts=29786400@180000"), failure.userMessage)
            XCTAssertTrue(failure.userMessage.contains("initialStart=10@1"), failure.userMessage)
            XCTAssertEqual(failure.code, "playback.hls.mediaGraph.runtime")
            XCTAssertEqual(failure.retryDisposition, .retrySameRequest)
            XCTAssertLessThanOrEqual(snapshot.summary.utf8.count - snapshot.typeName.utf8.count - 3, 256)
        }
    }

    func testInterlacedTimingKeepsExactValuesAndTimescalesThroughPrivacyRedaction() {
        let times = [
            CMTime(value: 29_786_400, timescale: 180_000),
            CMTime(value: 3_600, timescale: 180_000),
            CMTime(value: 29_782_800, timescale: 180_000),
            CMTime(value: -1, timescale: 90_000),
            CMTime(value: 10, timescale: 1),
        ]
        let text = times.map(HLSInterlacedOutputDiagnostic.time).joined(separator: " ")
        let snapshot = ErrorDiagnosticSnapshot(typeName: "timing", message: text)
        XCTAssertTrue(snapshot.summary.contains(
            "29786400@180000 3600@180000 29782800@180000 -1@90000 10@1"), snapshot.summary)
        XCTAssertFalse(snapshot.summary.contains("路径已隐藏"))
    }

    func testInterlacedSystemWriterErrorPreservesOriginalDomainAndCode() {
        let original = ErrorDiagnosticSnapshot(NSError(domain: "AVFoundationErrorDomain", code: -11_800,
            userInfo: [NSLocalizedDescriptionKey: "Writer rejected sample " + String(repeating: "说明📺", count: 200)]))
        let message = HLSInterlacedOutputDiagnostic.message(
            stage: "writerAppend", error: SegmentedFMP4WriterFailure.systemError(original),
            pts: .zero, expectedVideoStart: .zero, context: String(repeating: "context ", count: 100))
        let snapshot = PlaybackErrorDiagnostics.snapshot(PlaybackCoreError.videoSampleBuffer(message))
        let failure = PlaybackController.failure(for: .capture(snapshot, stage: "hls.mediaGraph.runtime"))

        XCTAssertTrue(failure.userMessage.contains("underlying=writer.systemError"), failure.userMessage)
        XCTAssertTrue(failure.userMessage.contains("AVFoundationErrorDomain(-11800)"), failure.userMessage)
        XCTAssertFalse(failure.userMessage.contains("�"))
        XCTAssertLessThanOrEqual(snapshot.summary.utf8.count - snapshot.typeName.utf8.count - 3, 256)
    }

    func testInterlacedUnknownCauseKeepsPrivacyAndUTF8Bounds() {
        let secrets = [
            ("https://private-fixture.invalid/live?token=fixture-secret", "地址已隐藏"),
            ("/Users/private-fixture/private-media.ts", "路径已隐藏"),
            ("token=fixture-secret", "凭据已隐藏"),
        ]
        for (secret, redaction) in secrets {
            let original = NSError(domain: "FixtureWriter", code: -42, userInfo: [
                NSLocalizedDescriptionKey: "\(secret) " + String(repeating: "说明📺", count: 200)
            ])
            let message = HLSInterlacedOutputDiagnostic.message(
                stage: "writerAppend", error: original, pts: .zero,
                expectedVideoStart: .zero, context: secret)
            let snapshot = PlaybackErrorDiagnostics.snapshot(PlaybackCoreError.videoSampleBuffer(message))
            let failure = PlaybackController.failure(for: .capture(snapshot, stage: "hls.mediaGraph.runtime"))

            XCTAssertTrue(failure.userMessage.contains(redaction), failure.userMessage)
            XCTAssertFalse(failure.userMessage.contains("private-fixture"), failure.userMessage)
            XCTAssertFalse(failure.userMessage.contains("private-media"), failure.userMessage)
            XCTAssertFalse(failure.userMessage.contains("fixture-secret"), failure.userMessage)
            XCTAssertFalse(failure.userMessage.contains("�"))
            XCTAssertLessThanOrEqual(snapshot.typeName.utf8.count, 128)
            XCTAssertLessThanOrEqual(snapshot.summary.utf8.count - snapshot.typeName.utf8.count - 3, 256)
        }
    }

    func testAssociatedFailureDetailsAreVisibleAndDistinguishDifferentCauses() {
        let pairs: [(PlaybackCoreError, PlaybackCoreError, String, String)] = [
            (.demuxOpen(-100), .demuxOpen(-200), "-100", "-200"),
            (.demuxRead(-101), .demuxRead(-201), "-101", "-201"),
            (.videoFormatDescription(-102), .videoFormatDescription(-202), "-102", "-202"),
            (.audioFormatDescription(-103), .audioFormatDescription(-203), "-103", "-203"),
            (.videoDecode(-104), .videoDecode(-204), "-104", "-204"),
            (.audioFallbackDecode(-105), .audioFallbackDecode(-205), "-105", "-205"),
            (.videoRendererFailed("显示器失效"), .videoRendererFailed("帧提交失败"), "显示器失效", "帧提交失败"),
            (.audioRendererFailed("音频设备失效"), .audioRendererFailed("音频排队失败"), "音频设备失效", "音频排队失败"),
            (.metalCommand("命令提交失败"), .metalCommand("纹理转换失败"), "命令提交失败", "纹理转换失败"),
        ]
        for (first, second, firstDetail, secondDetail) in pairs {
            let a = PlaybackController.failure(for: first)
            let b = PlaybackController.failure(for: second)
            XCTAssertNotEqual(a.userMessage, b.userMessage)
            XCTAssertTrue(a.userMessage.contains(firstDetail), a.userMessage)
            XCTAssertTrue(b.userMessage.contains(secondDetail), b.userMessage)
        }
    }

    func testPlaybackFailureInitializerRemainsSourceCompatibleAndDiagnosticDefaultsToNil() {
        let failure = PlaybackFailure(
            code: "video.decode",
            userMessage: "视频解码失败，请尝试其他频道。"
        )

        XCTAssertEqual(failure.code, "video.decode")
        XCTAssertEqual(failure.userMessage, "视频解码失败，请尝试其他频道。")
        XCTAssertNil(failure.diagnosticCode)
        XCTAssertEqual(failure.retryDisposition, .retrySameRequest)
    }

    func testVideoDecodeMappingDisplaysSignedStatusAndKeepsMachineDiagnostic() {
        let secret = "https://user:password@example.test/live?token=secret"
        let failure = PlaybackController.failure(for: .videoDecode(-12_909))

        XCTAssertEqual(failure.code, "video.decode")
        XCTAssertTrue(failure.userMessage.contains("视频解码失败"))
        XCTAssertTrue(failure.userMessage.contains("-12909"))
        XCTAssertEqual(failure.diagnosticCode, "video.decode.status.-12909")
        XCTAssertFalse(failure.diagnosticCode?.contains(secret) == true)
    }

    func testVideoDecoderTransitionTimeoutHasStableRetryableChineseFailure() {
        let failure = PlaybackController.failure(for: .videoDecoderTransitionTimeout)

        XCTAssertEqual(failure.code, "video.decoder-timeout")
        XCTAssertEqual(failure.userMessage, "视频解码器响应超时，请稍后重试。")
        XCTAssertEqual(failure.diagnosticCode, "video.decoder-transition.timeout")
        XCTAssertEqual(failure.retryDisposition, .retrySameRequest)
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
            (.videoDecoderTransitionTimeout, "video.decoder-timeout", "视频解码器响应超时，请稍后重试。"),
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
            XCTAssertTrue(failure.userMessage.hasPrefix(String(message.split(separator: "，")[0])), failure.userMessage)
        }
    }

    func testEveryCoreFailureMapsToExplicitRetryDisposition() {
        let cases: [(PlaybackCoreError, PlaybackRetryDisposition)] = [
            (.unsupportedProtocol("udp"), .chooseAnotherChannel),
            (.demuxOpen(-1), .retrySameRequest),
            (.demuxRead(-2), .retrySameRequest),
            (.networkTimeout, .retrySameRequest),
            (.unsupportedVideoCodec, .chooseAnotherChannel),
            (.unsupportedAudioCodec, .chooseAnotherChannel),
            (.videoFormatDescription(-3), .chooseAnotherChannel),
            (.hardwareDecoderUnavailable, .retrySameRequest),
            (.videoDecoderTransitionTimeout, .retrySameRequest),
            (.videoDecode(-4), .chooseAnotherChannel),
            (.videoSampleBuffer("sample"), .retrySameRequest),
            (.videoRendererFailed("renderer"), .retrySameRequest),
            (.audioFormatDescription(-5), .chooseAnotherChannel),
            (.audioFallbackDecode(-6), .chooseAnotherChannel),
            (.audioRendererFailed("renderer"), .retrySameRequest),
            (.renderTextureMapping, .retrySameRequest),
            (.metalCommand("command"), .retrySameRequest),
            (.cancelled, .doNotRetry),
        ]

        for (core, disposition) in cases {
            XCTAssertEqual(
                PlaybackController.failure(for: core).retryDisposition,
                disposition,
                "retry disposition mismatch for \(core)"
            )
        }
    }

    func testVideoDecoderFailuresRetainRequiredDistinctionsAtPipelineBoundary() {
        XCTAssertEqual(PlaybackPipeline.coreError(for: .sessionCreate(-7)), .videoDecoderFailure(.sessionCreate(-7)))
        XCTAssertEqual(PlaybackPipeline.coreError(for: .softwareDecoder), .videoDecoderFailure(.softwareDecoder))
        XCTAssertEqual(PlaybackPipeline.coreError(for: .badData(-8)), .videoDecoderFailure(.badData(-8)))
        XCTAssertEqual(PlaybackPipeline.coreError(for: .malfunction(-9)), .videoDecoderFailure(.malfunction(-9)))
        XCTAssertEqual(
            PlaybackPipeline.coreError(for: .backpressureTimeout),
            .videoDecoderFailure(.backpressureTimeout)
        )
    }

    func testVideoDecoderCausesRemainDistinctWithTheSameSystemStatus() {
        let causes: [VideoDecoderFailure] = [.sessionCreate(-17), .badData(-17), .malfunction(-17)]
        let messages = causes.map { PlaybackController.failure(for: PlaybackPipeline.coreError(for: $0)).userMessage }
        XCTAssertEqual(Set(messages).count, 3)
        XCTAssertTrue(messages[0].contains("sessionCreate"))
        XCTAssertTrue(messages[1].contains("badData"))
        XCTAssertTrue(messages[2].contains("malfunction"))
    }

    func testUnknownDecodeFailuresKeepTheirPreviousRetryDisposition() {
        let diagnostic = ErrorDiagnosticSnapshot(typeName: "ForeignDecodeError", message: "原始未知失败")
        let stages = ["video.assembly", "audio.pcm-output", "audio.renderer.replay-prune",
                      "audio.recovery.replay-prune", "audio.recovery.replay", "audio.renderer.configure",
                      "audio.renderer.retry-replay", "audio.renderer.reset", "audio.renderer.reset-pcm",
                      "audio.renderer.fallback", "audio.renderer.drive"]
        for stage in stages {
            let error = PlaybackCoreError.unexpected(stage: stage, diagnostic: diagnostic)
            XCTAssertEqual(PlaybackController.failure(for: error).retryDisposition, .chooseAnotherChannel, stage)
        }
        let outputError = PlaybackCoreError.unexpected(stage: "audio.renderer", diagnostic: diagnostic)
        XCTAssertEqual(PlaybackController.failure(for: outputError).retryDisposition, .retrySameRequest)
    }
}
