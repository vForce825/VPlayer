// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import Dispatch
import Foundation
import VPlayerCore

final class SystemAudioRenderer: AudioRenderer, @unchecked Sendable {
    let identity: AudioRendererIdentity
    let mediaKind: AudioRendererMediaKind
    let renderer: AVSampleBufferAudioRenderer

    private let callbackQueue: DispatchQueue
    private let notificationCenter: NotificationCenter
    private var statusObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var requesting = false
    private let failureLock = NSLock()
    private var firstFailureEvent: AudioRendererEvent?

    init(
        identity: AudioRendererIdentity,
        mediaKind: AudioRendererMediaKind,
        renderer: AVSampleBufferAudioRenderer = AVSampleBufferAudioRenderer(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.identity = identity
        self.mediaKind = mediaKind
        self.renderer = renderer
        self.notificationCenter = notificationCenter
        callbackQueue = DispatchQueue(
            label: "org.vplayer.playback.audio.renderer.\(identity.rawValue)",
            qos: .userInitiated
        )
    }

    deinit {
        if requesting {
            renderer.stopRequestingMediaData()
        }
        statusObservation?.invalidate()
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
    }

    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        renderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) throws -> AudioRendererEnqueueResult {
        let formatID = CMSampleBufferGetFormatDescription(sampleBuffer)
            .map(CMFormatDescriptionGetMediaSubType) ?? 0
        let isPCM = formatID == kAudioFormatLinearPCM
        guard isPCM == (mediaKind == .linearPCM) else {
            throw PlaybackCoreError.audioRendererFailed("renderer.media-kind")
        }
        guard isReadyForMoreMediaData else { return .backpressured }
        renderer.enqueue(sampleBuffer)
        return .accepted
    }

    func flush() {
        renderer.flush()
    }

    func requestMediaDataWhenReady(_ handler: @escaping @Sendable () -> Void) {
        guard !requesting else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: callbackQueue, using: handler)
    }

    func stopRequestingMediaData() {
        guard requesting else { return }
        requesting = false
        renderer.stopRequestingMediaData()
    }

    func startObserving(_ handler: @escaping @Sendable (AudioRendererEvent) -> Void) {
        stopObserving()
        statusObservation = renderer.observe(\.status, options: [.new]) { [weak self] renderer, _ in
            guard let self, renderer.status == .failed else { return }
            handler(recordedFailureEvent(renderer.error))
        }
        let flushed = notificationCenter.addObserver(
            forName: Notification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { notification in
            let copiedTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey]
                as? NSValue)?.timeValue
            handler(.automaticFlush(copiedTime))
        }
        let configuration = notificationCenter.addObserver(
            forName: Notification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer,
            queue: nil
        ) { _ in
            handler(.outputConfigurationChanged)
        }
        notificationTokens = [flushed, configuration]
    }

    func stopObserving() {
        statusObservation?.invalidate()
        statusObservation = nil
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll(keepingCapacity: false)
    }

    /// 首错属于真实 renderer 实例；监听重绑不为同一失败实例重建诊断实体。
    func recordedFailureEvent(_ error: (any Error)?) -> AudioRendererEvent {
        failureLock.lock()
        defer { failureLock.unlock() }
        if let firstFailureEvent { return firstFailureEvent }
        let event = Self.failureEvent(error)
        firstFailureEvent = event
        return event
    }

    static func failureEvent(_ error: (any Error)?) -> AudioRendererEvent {
        guard let error else {
            return .failedWithDiagnostic(reason: "AVFoundation:unknown", diagnostic: .init(
                typeName: "AVSampleBufferAudioRenderer", code: "error-unavailable",
                message: "系统报告音频渲染器失败，但未提供错误详情。"))
        }
        let value = error as NSError
        // 先截取借用的 NSString，避免为旧 metrics 复制未知长度的原始域。
        let selector = #selector(getter: NSError.domain)
        let borrowedDomain = value.responds(to: selector)
            ? value.perform(selector)?.takeUnretainedValue() as? NSString : nil
        let domain = borrowedDomain?.substring(to: min(borrowedDomain?.length ?? 0, 96)) ?? "unknown"
        return .failedWithDiagnostic(reason: "\(domain):\(value.code)", diagnostic: .init(error))
    }
}

final class SystemAudioRendererFactory: AudioRendererFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var nextIdentity: UInt64? = 1

    func makeRenderer(mediaKind: AudioRendererMediaKind) throws -> any AudioRenderer {
        let identity: UInt64? = withLock {
            guard let current = nextIdentity else { return nil }
            nextIdentity = current == UInt64.max ? nil : current + 1
            return current
        }
        guard let identity else {
            throw PlaybackCoreError.audioRendererFailed("renderer.identity-exhausted")
        }
        return SystemAudioRenderer(
            identity: AudioRendererIdentity(rawValue: identity),
            mediaKind: mediaKind
        )
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class SystemAudioSynchronizer: AudioRenderSynchronizing, @unchecked Sendable {
    let synchronizer: AVSampleBufferRenderSynchronizer

    init(_ synchronizer: AVSampleBufferRenderSynchronizer) {
        self.synchronizer = synchronizer
    }

    func currentTime() -> CMTime { synchronizer.currentTime() }
    var rate: Float { synchronizer.rate }

    func attach(_ renderer: any AudioRenderer) throws {
        guard let renderer = renderer as? SystemAudioRenderer else {
            throw PlaybackCoreError.audioRendererFailed("audio.renderer.type-mismatch")
        }
        synchronizer.addRenderer(renderer.renderer)
    }

    func remove(
        _ renderer: any AudioRenderer,
        at time: CMTime,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let renderer = renderer as? SystemAudioRenderer else {
            completion(false)
            return
        }
        synchronizer.removeRenderer(
            renderer.renderer,
            at: time,
            completionHandler: completion
        )
    }

    func setRate(_ rate: Float, time: CMTime) {
        synchronizer.setRate(rate, time: time)
    }
}
