// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

private final class NoopPlaybackAudioSessionOwner: PlaybackAudioSessionOwning,
    @unchecked Sendable {
    @MainActor private var nextID: UInt64 = 1

    @MainActor
    func acquire(
        eventHandler _: @escaping @MainActor @Sendable (
            PlaybackAudioSessionLease,
            PlaybackAudioSessionEvent
        ) -> Void
    ) throws -> PlaybackAudioSessionLease {
        defer { nextID &+= 1 }
        return PlaybackAudioSessionLease(id: nextID, generation: nextID)
    }

    @MainActor
    func release(_: PlaybackAudioSessionLease) {}

    @MainActor
    func requestResume(for _: PlaybackAudioSessionLease) -> Bool { false }
}

protocol PlaybackTerminalMetricsProviding: Sendable {
    func snapshot(window: Duration) -> PlaybackMetricsSnapshot
}

extension PlaybackMetrics: PlaybackTerminalMetricsProviding {}

public actor PlaybackController: PlaybackEngine, PlaybackMetricsProviding,
    PlaybackMediaInformationProviding {
    private let factory: any PlaybackPipelineFactory
    private let audioSessionOwner: any PlaybackAudioSessionOwning
    private var audioSessionLease: PlaybackAudioSessionLease?
    private var state = PlaybackState.idle
    private var pipeline: (any PlaybackPipelineProtocol)?
    private var request: PlaybackRequest?
    private var userPaused = false
    private var sessionID: UInt64 = 0
    private var activeRunIdentity: PlaybackRunIdentity?
    private var eventRelay: PlaybackSessionEventRelay?
    private var audioSessionEventRelay: PlaybackAudioSessionEventRelay?
    private var terminalMetricsProvider: (any PlaybackTerminalMetricsProviding)?
    private var mediaGeneration: MediaGeneration?
    private var currentMediaInformation: PlaybackMediaInformation?
    private var readinessCycle: UInt64 = 0
    private var pendingTeardown: Task<Void, Never>?
    private var interruptionActive = false
    private var systemPauseRequired = false
    private var resumeVetoRequired = false
    private var resumeRequestInFlight = false
    private var pendingAudioSessionReset = false
    private var eventContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var mediaInformationContinuations:
        [UUID: AsyncStream<PlaybackMediaInformation?>.Continuation] = [:]
    private var tuning = PlaybackTuning.default
    private static let audioSessionActivationFailure = PlaybackFailure(
        code: "audio.session.activation",
        userMessage: "无法启用音频播放，请检查播放设备后重试。"
    )

    @MainActor
    public init() {
        factory = SystemPlaybackPipelineFactory()
        audioSessionOwner = PlaybackAudioSessionOwner()
    }

    init(factory: any PlaybackPipelineFactory) {
        self.factory = factory
        audioSessionOwner = NoopPlaybackAudioSessionOwner()
    }

    init(
        factory: any PlaybackPipelineFactory,
        audioSessionOwner: any PlaybackAudioSessionOwning
    ) {
        self.factory = factory
        self.audioSessionOwner = audioSessionOwner
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
        let identity = PlaybackRunIdentity(sessionID: sessionID, requestID: request.id)
        activeRunIdentity = identity
        eventRelay = nil
        terminalMetricsProvider = nil
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
        guard isCurrent(identity) else { return }
        pendingTeardown = nil

        let previousLease = audioSessionLease
        let audioRelay = PlaybackAudioSessionEventRelay(identity: identity) {
            [weak self] identity, lease, event in
            await self?.receiveAudioSession(event, lease: lease, identity: identity)
        }
        audioSessionEventRelay = audioRelay
        do {
            let lease = try await audioSessionOwner.acquire { lease, event in
                audioRelay.send(lease: lease, event: event)
            }
            guard isCurrent(identity) else {
                audioRelay.deactivate()
                await audioSessionOwner.release(lease)
                return
            }
            audioSessionLease = lease
            interruptionActive = lease.isInterruptedAtAcquisition
            systemPauseRequired = lease.isInterruptedAtAcquisition
            if systemPauseRequired { advanceReadinessCycle() }
            pendingAudioSessionReset = false
            if let previousLease {
                await audioSessionOwner.release(previousLease)
            }
        } catch {
            guard isCurrent(identity) else {
                audioRelay.deactivate()
                return
            }
            audioRelay.deactivate()
            if audioSessionEventRelay === audioRelay { audioSessionEventRelay = nil }
            if let previousLease {
                await audioSessionOwner.release(previousLease)
                if audioSessionLease == previousLease { audioSessionLease = nil }
            }
            publish(.failed(Self.audioSessionActivationFailure))
            return
        }

        let relay = PlaybackSessionEventRelay(identity: identity) { [weak self] identity, event in
            await self?.receive(event, identity: identity)
        }
        eventRelay = relay
        do {
            let next = try await factory.makePipeline(
                tuning: tuning,
                channelID: request.channelID
            ) { event in
                relay.send(event)
            }
            guard isCurrent(identity) else {
                relay.deactivate()
                await next.stop()
                return
            }
            pipeline = next
            if systemPauseRequired, !userPaused {
                publish(resumeVetoRequired ? .paused(request) : .recovering(request))
            }
            next.start(
                url: request.streamURL,
                readinessCycle: readinessCycle,
                initiallyPaused: userPaused || systemPauseRequired
            )
            if pendingAudioSessionReset {
                pendingAudioSessionReset = false
                next.recoverFromAudioSessionReset(readinessCycle: readinessCycle)
            }
        } catch let error as PlaybackCoreError {
            guard isCurrent(identity) else {
                relay.deactivate()
                return
            }
            relay.deactivate()
            eventRelay = nil
            audioSessionEventRelay?.deactivate()
            audioSessionEventRelay = nil
            await releaseAudioSessionLease()
            guard isCurrent(identity) else { return }
            publish(.failed(Self.failure(for: error)))
        } catch {
            guard isCurrent(identity) else {
                relay.deactivate()
                return
            }
            relay.deactivate()
            eventRelay = nil
            audioSessionEventRelay?.deactivate()
            audioSessionEventRelay = nil
            await releaseAudioSessionLease()
            guard isCurrent(identity) else { return }
            publish(.failed(Self.failure(for: .demuxOpen(-1))))
        }
    }

    public func setPaused(_ paused: Bool) async {
        guard let request else { return }
        switch state {
        case .failed, .stopped, .idle:
            return
        case .preparing, .buffering, .recovering, .playing, .paused:
            break
        }
        if !paused, resumeVetoRequired {
            userPaused = false
            publish(.paused(request))
            guard !interruptionActive,
                  !resumeRequestInFlight,
                  let lease = audioSessionLease else { return }
            resumeRequestInFlight = true
            let accepted = await audioSessionOwner.requestResume(for: lease)
            if !accepted { resumeRequestInFlight = false }
            return
        }
        guard userPaused != paused else { return }
        userPaused = paused
        advanceReadinessCycle()
        if paused {
            pipeline?.setPaused(true, readinessCycle: readinessCycle)
            publish(.paused(request))
        } else if systemPauseRequired {
            publish(.recovering(request))
        } else {
            pipeline?.setPaused(false, readinessCycle: readinessCycle)
            publish(.preparing(request))
        }
    }

    public func stop() async {
        terminalMetricsProvider = nil
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
        await releaseAudioSessionLease()
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
            ?? terminalMetricsProvider?.snapshot(window: window)
    }

    var currentStateForTesting: PlaybackState { state }
    var audioSessionInterruptedForTesting: Bool { interruptionActive }
    var readinessCycleForTesting: UInt64 { readinessCycle }

    static func failure(for error: PlaybackCoreError) -> PlaybackFailure {
        let mapped = switch error {
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
        case .videoDecoderTransitionTimeout:
            PlaybackFailure(
                code: "video.decoder-timeout",
                userMessage: "视频解码器响应超时，请稍后重试。",
                diagnosticCode: "video.decoder-transition.timeout"
            )
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
        return PlaybackFailure(
            code: mapped.code,
            userMessage: mapped.userMessage,
            diagnosticCode: mapped.diagnosticCode,
            retryDisposition: error.retryDisposition
        )
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

    private func receive(_ event: PlaybackPipelineEvent, identity: PlaybackRunIdentity) async {
        guard isCurrent(identity), pipeline != nil else { return }
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
                  !systemPauseRequired,
                  eventCycle == readinessCycle else { return }
            publish(.playing(request))
        case let .phase(phase, eventCycle):
            guard let request,
                  !userPaused,
                  !systemPauseRequired,
                  !resumeVetoRequired,
                  eventCycle == readinessCycle else { return }
            switch phase {
            case .buffering:
                publish(.buffering(request))
            case .recovering:
                publish(.recovering(request))
            }
        case .stopped:
            pipeline = nil
            eventRelay?.deactivate()
            eventRelay = nil
            audioSessionEventRelay?.deactivate()
            audioSessionEventRelay = nil
            resumeRequestInFlight = false
            request = nil
            userPaused = false
            clearMediaInformation()
            await releaseAudioSessionLease()
            publish(.stopped)
        case let .failed(error):
            terminalMetricsProvider = pipeline?.terminalMetricsProvider
            pipeline = nil
            eventRelay?.deactivate()
            eventRelay = nil
            audioSessionEventRelay?.deactivate()
            audioSessionEventRelay = nil
            resumeRequestInFlight = false
            request = nil
            userPaused = false
            clearMediaInformation()
            await releaseAudioSessionLease()
            publish(.failed(Self.failure(for: error)))
        }
    }

    private func receiveAudioSession(
        _ event: PlaybackAudioSessionEvent,
        lease: PlaybackAudioSessionLease,
        identity: PlaybackRunIdentity
    ) async {
        guard isCurrent(identity), audioSessionLease == lease,
              let request else { return }
        switch event {
        case .interruptionBegan:
            guard !interruptionActive else { return }
            interruptionActive = true
            systemPauseRequired = true
            advanceReadinessCycle()
            pipeline?.setPaused(true, readinessCycle: readinessCycle)
            if !userPaused {
                publish(resumeVetoRequired ? .paused(request) : .recovering(request))
            }
        case .mediaServicesWereReset:
            let releaseSystemPause = systemPauseRequired
                && !resumeVetoRequired
                && !userPaused
            interruptionActive = false
            if !resumeVetoRequired { systemPauseRequired = false }
            advanceReadinessCycle()
            if let pipeline {
                pipeline.recoverFromAudioSessionReset(readinessCycle: readinessCycle)
                if releaseSystemPause {
                    pipeline.setPaused(false, readinessCycle: readinessCycle)
                }
            } else {
                pendingAudioSessionReset = true
            }
            if !userPaused {
                publish(resumeVetoRequired ? .paused(request) : .recovering(request))
            }
        case let .interruptionEnded(shouldResume):
            interruptionActive = false
            resumeRequestInFlight = false
            guard shouldResume else {
                resumeVetoRequired = true
                systemPauseRequired = true
                if !userPaused { publish(.paused(request)) }
                return
            }
            resumeVetoRequired = false
            systemPauseRequired = false
            guard !userPaused else { return }
            if let pipeline {
                pipeline.setPaused(false, readinessCycle: readinessCycle)
            }
            publish(.preparing(request))
        case .explicitResumeSucceeded:
            resumeRequestInFlight = false
            guard resumeVetoRequired, !interruptionActive else { return }
            resumeVetoRequired = false
            systemPauseRequired = false
            guard !userPaused else { return }
            pipeline?.setPaused(false, readinessCycle: readinessCycle)
            publish(.preparing(request))
        case .recoveryFailed:
            await failCurrentAudioSessionRecovery(
                lease: lease,
                identity: identity
            )
        }
    }

    private func failCurrentAudioSessionRecovery(
        lease: PlaybackAudioSessionLease,
        identity: PlaybackRunIdentity
    ) async {
        guard isCurrent(identity), audioSessionLease == lease else { return }
        let current = pipeline
        terminalMetricsProvider = current?.terminalMetricsProvider
        invalidateSession()
        let failedSessionID = sessionID
        pipeline = nil
        audioSessionLease = nil
        request = nil
        userPaused = false
        readinessCycle = 0
        clearMediaInformation()
        if let current {
            let audioSessionOwner = self.audioSessionOwner
            let teardown = Task {
                await current.stop()
                await audioSessionOwner.release(lease)
            }
            pendingTeardown = teardown
            await teardown.value
        } else {
            await audioSessionOwner.release(lease)
        }
        guard sessionID == failedSessionID else { return }
        pendingTeardown = nil
        publish(.failed(Self.audioSessionActivationFailure))
    }

    private func releaseAudioSessionLease() async {
        guard let lease = audioSessionLease else { return }
        audioSessionLease = nil
        await audioSessionOwner.release(lease)
    }

    private func invalidateSession() {
        sessionID &+= 1
        activeRunIdentity = nil
        interruptionActive = false
        systemPauseRequired = false
        resumeVetoRequired = false
        resumeRequestInFlight = false
        pendingAudioSessionReset = false
        eventRelay?.deactivate()
        eventRelay = nil
        audioSessionEventRelay?.deactivate()
        audioSessionEventRelay = nil
    }

    private func isCurrent(_ identity: PlaybackRunIdentity) -> Bool {
        activeRunIdentity == identity && identity.sessionID == sessionID
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

    private func removeMediaInformationContinuation(_ id: UUID) {
        mediaInformationContinuations[id] = nil
    }
}
