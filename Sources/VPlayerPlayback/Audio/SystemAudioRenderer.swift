// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import Dispatch
import Foundation

final class SystemAudioRenderer: AudioRenderer, @unchecked Sendable {
    let identity: AudioRendererIdentity
    let mediaKind: AudioRendererMediaKind
    let renderer: AVSampleBufferAudioRenderer

    private let callbackQueue: DispatchQueue
    private let notificationCenter: NotificationCenter
    private var statusObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var requesting = false

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

    func enqueue(_ sampleBuffer: CMSampleBuffer) throws {
        guard isReadyForMoreMediaData else {
            throw PlaybackCoreError.audioRendererFailed("renderer.not-ready")
        }
        let formatID = CMSampleBufferGetFormatDescription(sampleBuffer)
            .map(CMFormatDescriptionGetMediaSubType) ?? 0
        let isPCM = formatID == kAudioFormatLinearPCM
        guard isPCM == (mediaKind == .linearPCM) else {
            throw PlaybackCoreError.audioRendererFailed("renderer.media-kind")
        }
        renderer.enqueue(sampleBuffer)
    }

    func flush() {
        renderer.flush()
    }

    func requestMediaDataWhenReady(_ handler: @escaping @Sendable () -> Void) {
        if requesting {
            renderer.stopRequestingMediaData()
        }
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
        statusObservation = renderer.observe(\.status, options: [.new]) { renderer, _ in
            guard renderer.status == .failed else { return }
            handler(.failed(Self.sanitized(renderer.error)))
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

    private static func sanitized(_ error: (any Error)?) -> String {
        guard let error else { return "AVFoundation:unknown" }
        let value = error as NSError
        let domain = String(value.domain.prefix(96))
        return "\(domain):\(value.code)"
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

    func attach(_ renderer: any AudioRenderer) {
        guard let renderer = renderer as? SystemAudioRenderer else { return }
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

struct SystemAudioFormatSupportChecker: AudioFormatSupportChecking {
    func supports(
        format: CMAudioFormatDescription,
        route: AudioRoute,
        output _: AudioOutputCategory
    ) -> Bool {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return false
        }
        if route == .ffmpegPCM {
            return asbd.mFormatID == kAudioFormatLinearPCM &&
                asbd.mSampleRate > 0 && asbd.mChannelsPerFrame > 0 &&
                asbd.mBitsPerChannel == 32 &&
                asbd.mBytesPerFrame == asbd.mChannelsPerFrame * 4 &&
                asbd.mFramesPerPacket == 1
        }

        var byteCount: UInt32 = 0
        guard AudioFormatGetPropertyInfo(
            kAudioFormatProperty_DecodeFormatIDs,
            0,
            nil,
            &byteCount
        ) == noErr,
        byteCount > 0,
        byteCount % UInt32(MemoryLayout<AudioFormatID>.size) == 0 else {
            return false
        }
        let count = Int(byteCount) / MemoryLayout<AudioFormatID>.size
        var formats = [AudioFormatID](repeating: 0, count: count)
        let status = formats.withUnsafeMutableBytes { buffer in
            AudioFormatGetProperty(
                kAudioFormatProperty_DecodeFormatIDs,
                0,
                nil,
                &byteCount,
                buffer.baseAddress
            )
        }
        return status == noErr && formats.contains(asbd.mFormatID)
    }
}
