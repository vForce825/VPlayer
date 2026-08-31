// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation

protocol PlaybackAudioSessionPreparing: Sendable {
    func prepareForPlayback() throws
}

struct SystemPlaybackAudioSessionPreparer: PlaybackAudioSessionPreparing {
    func prepareForPlayback() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }
}

private struct NoopPlaybackAudioSessionPreparer: PlaybackAudioSessionPreparing {
    func prepareForPlayback() throws {}
}

public actor PlaybackController: PlaybackEngine, PlaybackMetricsProviding,
    PlaybackMediaInformationProviding {
    private let factory: any PlaybackPipelineFactory
    private let audioSessionPreparer: any PlaybackAudioSessionPreparing
    private var state = PlaybackState.idle
    private var pipeline: (any PlaybackPipelineProtocol)?
    private var request: PlaybackRequest?
    private var userPaused = false
    private var sessionID: UInt64 = 0
    private var mediaGeneration: MediaGeneration?
    private var currentMediaInformation: PlaybackMediaInformation?
    private var readinessCycle: UInt64 = 0
    private var pendingTeardown: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var noticeContinuations: [UUID: AsyncStream<PlaybackNotice>.Continuation] = [:]
    private var mediaInformationContinuations:
        [UUID: AsyncStream<PlaybackMediaInformation?>.Continuation] = [:]
    private var tuning = PlaybackTuning.default
    private static let audioSessionActivationFailure = PlaybackFailure(
        code: "audio.session.activation",
        userMessage: "无法启用音频播放，请检查播放设备后重试。"
    )

    public init() {
        factory = SystemPlaybackPipelineFactory()
        audioSessionPreparer = SystemPlaybackAudioSessionPreparer()
    }

    init(factory: any PlaybackPipelineFactory) {
        self.factory = factory
        audioSessionPreparer = NoopPlaybackAudioSessionPreparer()
    }

    init(
        factory: any PlaybackPipelineFactory,
        audioSessionPreparer: any PlaybackAudioSessionPreparing
    ) {
        self.factory = factory
        self.audioSessionPreparer = audioSessionPreparer
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

    public func playbackMediaInformation() -> AsyncStream<PlaybackMediaInformation?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackMediaInformation?.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        mediaInformationContinuations[id] = continuation
        _ = continuation.yield(currentMediaInformation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeMediaInformationContinuation(id) }
        }
        return stream
    }

    public func play(_ request: PlaybackRequest) async {
        invalidateSession()
        let id = sessionID
        let previous = pipeline
        pipeline = nil
        clearMediaInformation()
        self.request = request
        userPaused = false
        readinessCycle = 0
        publish(.preparing(request))
        let teardown: Task<Void, Never>?
        if let previous {
            let task = Task { await previous.stop() }
            pendingTeardown = task
            teardown = task
        } else {
            teardown = pendingTeardown
        }
        if let teardown { await teardown.value }
        guard sessionID == id else { return }
        pendingTeardown = nil

        do {
            // tvOS 的 setActive 是同步操作。只有它成功返回后才创建管线，
            // 因而音频路由监视器采集的是本次激活后的 currentRoute。
            try audioSessionPreparer.prepareForPlayback()
        } catch {
            publish(.failed(Self.audioSessionActivationFailure))
            return
        }

        do {
            let next = try await factory.makePipeline(
                tuning: tuning,
                channelID: request.channelID
            ) { [weak self] event in
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
        guard userPaused != paused else { return }
        userPaused = paused
        advanceReadinessCycle()
        pipeline?.setPaused(paused, readinessCycle: readinessCycle)
        publish(paused ? .paused(request) : .preparing(request))
    }

    public func stop() async {
        guard pipeline != nil || request != nil || pendingTeardown != nil else { return }
        invalidateSession()
        let id = sessionID
        let current = pipeline
        pipeline = nil
        clearMediaInformation()
        request = nil
        userPaused = false
        readinessCycle = 0
        let teardown: Task<Void, Never>?
        if let current {
            let task = Task { await current.stop() }
            pendingTeardown = task
            teardown = task
        } else {
            teardown = pendingTeardown
        }
        if let teardown { await teardown.value }
        guard sessionID == id else { return }
        pendingTeardown = nil
        publish(.stopped)
    }

    public func setTuning(_ tuning: PlaybackTuning) async {
        self.tuning = tuning
        pipeline?.setTuning(tuning)
    }

    public func presentationContext() -> PlaybackPresentationContext? {
        pipeline?.presentationContext
    }

    public func playbackMetricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot? {
        pipeline?.metricsSnapshot(window: window)
    }

    var currentStateForTesting: PlaybackState { state }

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
        case let .videoDecode(status):
            PlaybackFailure(
                code: "video.decode",
                userMessage: "视频解码失败，请尝试其他频道。",
                diagnosticCode: "video.decode.status.\(status)"
            )
        case let .videoSampleBuffer(reason):
            PlaybackFailure(
                code: "video.sample-buffer",
                userMessage: "视频帧处理失败，请稍后重试。",
                diagnosticCode: "video.sample-buffer.reason.\(safeRendererReason(reason))"
            )
        case let .videoRendererFailed(reason):
            PlaybackFailure(
                code: "video.renderer",
                userMessage: "视频输出失败，请稍后重试。",
                diagnosticCode: "video.renderer.reason.\(safeRendererReason(reason))"
            )
        case .audioFormatDescription:
            PlaybackFailure(code: "audio.format", userMessage: "无法解析音频格式，请尝试其他频道。")
        case let .audioFallbackDecode(status):
            PlaybackFailure(
                code: "audio.decode",
                userMessage: "音频解码失败，请尝试其他频道。",
                diagnosticCode: "audio.decode.status.\(status)"
            )
        case let .audioRendererFailed(reason):
            PlaybackFailure(
                code: "audio.renderer",
                userMessage: "音频输出失败，请检查播放设备后重试。",
                diagnosticCode: "audio.renderer.reason.\(safeAudioRendererReason(reason))"
            )
        case .renderTextureMapping:
            PlaybackFailure(code: "video.texture", userMessage: "视频纹理处理失败，请稍后重试。")
        case .metalCommand:
            PlaybackFailure(code: "metal.command", userMessage: "视频渲染失败，请稍后重试。")
        case .cancelled:
            PlaybackFailure(code: "playback.cancelled", userMessage: "播放已取消，请重新选择频道。")
        }
    }

    private static func safeAudioRendererReason(_ reason: String) -> String {
        safeRendererReason(reason)
    }

    private static func safeRendererReason(_ reason: String) -> String {
        guard !reason.isEmpty, reason.utf8.count <= 128,
              reason.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45...46, 48...58, 65...90, 95, 97...122:
                      true
                  default:
                      false
                  }
              }) else { return "unknown" }
        return reason
    }

    private func receive(_ event: PlaybackPipelineEvent, sessionID: UInt64) {
        guard sessionID == self.sessionID, pipeline != nil else { return }
        switch event {
        case let .mediaInformation(information, generation: eventGeneration?):
            guard mediaGeneration.map({ eventGeneration >= $0 }) ?? true else { return }
            if mediaGeneration != eventGeneration {
                mediaGeneration = eventGeneration
                // A generation transition invalidates the previous snapshot.
                // The event itself may already be the transition's nil marker,
                // so avoid publishing that marker twice.
                if currentMediaInformation != nil, information != nil {
                    publishMediaInformation(nil)
                }
            }
            publishMediaInformation(information)
        case let .mediaInformation(information, generation: nil):
            publishMediaInformation(information)
        case let .ready(eventCycle):
            guard let request,
                  !userPaused,
                  eventCycle == readinessCycle else { return }
            publish(.playing(request))
        case .stopped:
            pipeline = nil
            request = nil
            userPaused = false
            clearMediaInformation()
            publish(.stopped)
        case let .failed(error):
            pipeline = nil
            request = nil
            userPaused = false
            clearMediaInformation()
            publish(.failed(Self.failure(for: error)))
        }
    }

    private func invalidateSession() {
        sessionID &+= 1
    }

    private func advanceReadinessCycle() {
        if readinessCycle < UInt64.max { readinessCycle += 1 }
    }

    private func publish(_ newState: PlaybackState) {
        guard state != newState else { return }
        state = newState
        for continuation in eventContinuations.values {
            _ = continuation.yield(newState)
        }
    }

    private func publishMediaInformation(_ information: PlaybackMediaInformation?) {
        currentMediaInformation = information
        for continuation in mediaInformationContinuations.values {
            _ = continuation.yield(information)
        }
    }

    private func clearMediaInformation() {
        guard currentMediaInformation != nil || mediaGeneration != nil else { return }
        mediaGeneration = nil
        publishMediaInformation(nil)
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func removeNoticeContinuation(_ id: UUID) {
        noticeContinuations[id] = nil
    }

    private func removeMediaInformationContinuation(_ id: UUID) {
        mediaInformationContinuations[id] = nil
    }
}
