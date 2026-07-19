// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public actor PlaybackController: PlaybackEngine {
    private let factory: any PlaybackPipelineFactory
    private var state = PlaybackState.idle
    private var pipeline: (any PlaybackPipelineProtocol)?
    private var request: PlaybackRequest?
    private var userPaused = false
    private var sessionID: UInt64 = 0
    private var eventContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var noticeContinuations: [UUID: AsyncStream<PlaybackNotice>.Continuation] = [:]
    private var selectedAlgorithm = DeinterlaceAlgorithm.appleTemporal

    public init() {
        factory = SystemPlaybackPipelineFactory()
    }

    init(factory: any PlaybackPipelineFactory) {
        self.factory = factory
    }

    public func events() -> AsyncStream<PlaybackState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackState.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        eventContinuations[id] = continuation
        _ = continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return stream
    }

    public func notices() -> AsyncStream<PlaybackNotice> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackNotice.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        noticeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNoticeContinuation(id) }
        }
        return stream
    }

    public func play(_ request: PlaybackRequest) async {
        invalidateSession()
        pipeline?.stop()
        pipeline = nil
        self.request = request
        userPaused = false
        publish(.preparing(request))

        let id = sessionID
        do {
            let next = try factory.makePipeline { [weak self] event in
                Task { await self?.receive(event, sessionID: id) }
            }
            pipeline = next
            next.start(url: request.streamURL)
        } catch let error as PlaybackCoreError {
            publish(.failed(Self.failure(for: error)))
        } catch {
            publish(.failed(Self.failure(for: .demuxOpen(-1))))
        }
    }

    public func setPaused(_ paused: Bool) async {
        guard let request, pipeline != nil else { return }
        switch state {
        case .failed, .stopped, .idle:
            return
        case .preparing, .playing, .paused:
            break
        }
        userPaused = paused
        pipeline?.setPaused(paused)
        publish(paused ? .paused(request) : .preparing(request))
    }

    public func stop() async {
        invalidateSession()
        let current = pipeline
        pipeline = nil
        request = nil
        userPaused = false
        current?.stop()
        publish(.stopped)
    }

    public func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm) async {
        selectedAlgorithm = algorithm
    }

    var currentStateForTesting: PlaybackState { state }
    var selectedDeinterlaceAlgorithmForTesting: DeinterlaceAlgorithm { selectedAlgorithm }

    static func failure(for error: PlaybackCoreError) -> PlaybackFailure {
        switch error {
        case .unsupportedProtocol:
            PlaybackFailure(code: "protocol.unsupported", userMessage: "不支持此播放协议，请使用 HTTP 或 HTTPS 地址。")
        case .demuxOpen:
            PlaybackFailure(code: "demux.open", userMessage: "无法打开频道流，请检查地址和网络后重试。")
        case .demuxRead:
            PlaybackFailure(code: "demux.read", userMessage: "读取频道流失败，请检查网络后重试。")
        case .networkTimeout:
            PlaybackFailure(code: "network.timeout", userMessage: "连接频道超时，请检查网络后重试。")
        case .unsupportedVideoCodec:
            PlaybackFailure(code: "video.codec", userMessage: "不支持此频道的视频编码，请尝试其他频道。")
        case .unsupportedAudioCodec:
            PlaybackFailure(code: "audio.codec", userMessage: "不支持此频道的音频编码，请尝试其他频道。")
        case .videoFormatDescription:
            PlaybackFailure(code: "video.format", userMessage: "无法解析视频格式，请尝试其他频道。")
        case .hardwareDecoderUnavailable:
            PlaybackFailure(code: "video.hardware", userMessage: "硬件视频解码器不可用，请稍后重试。")
        case .videoDecode:
            PlaybackFailure(code: "video.decode", userMessage: "视频解码失败，请尝试其他频道。")
        case .audioFormatDescription:
            PlaybackFailure(code: "audio.format", userMessage: "无法解析音频格式，请尝试其他频道。")
        case .audioFallbackDecode:
            PlaybackFailure(code: "audio.decode", userMessage: "音频解码失败，请尝试其他频道。")
        case .audioRendererFailed:
            PlaybackFailure(code: "audio.renderer", userMessage: "音频输出失败，请检查播放设备后重试。")
        case .renderTextureMapping:
            PlaybackFailure(code: "video.texture", userMessage: "视频纹理处理失败，请稍后重试。")
        case .metalCommand:
            PlaybackFailure(code: "metal.command", userMessage: "视频渲染失败，请稍后重试。")
        case .cancelled:
            PlaybackFailure(code: "playback.cancelled", userMessage: "播放已取消，请重新选择频道。")
        }
    }

    private func receive(_ event: PlaybackPipelineEvent, sessionID: UInt64) {
        guard sessionID == self.sessionID, pipeline != nil else { return }
        switch event {
        case .ready:
            guard let request, !userPaused else { return }
            publish(.playing(request))
        case .stopped:
            pipeline = nil
            request = nil
            userPaused = false
            publish(.stopped)
        case let .failed(error):
            pipeline = nil
            request = nil
            userPaused = false
            publish(.failed(Self.failure(for: error)))
        }
    }

    private func invalidateSession() {
        sessionID &+= 1
    }

    private func publish(_ newState: PlaybackState) {
        state = newState
        for continuation in eventContinuations.values {
            _ = continuation.yield(newState)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func removeNoticeContinuation(_ id: UUID) {
        noticeContinuations[id] = nil
    }
}
