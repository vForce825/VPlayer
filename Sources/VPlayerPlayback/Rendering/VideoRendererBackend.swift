// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Dispatch
import Foundation

enum VideoRendererBackendEvent: @unchecked Sendable {
    case failed(any Error)
    case requiresFlushToResumeDecoding
}

protocol SampleBufferVideoRenderingBackend: AnyObject, Sendable {
    var isReadyForMoreMediaData: Bool { get }
    var status: AVQueuedSampleBufferRenderingStatus { get }
    var error: (any Error)? { get }
    var requiresFlushToResumeDecoding: Bool { get }

    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    )
    func stopRequestingMediaData()
    func flush(
        removeDisplayedImage: Bool,
        completion: @escaping @Sendable () -> Void
    )
    func startObserving(_ handler: @escaping @Sendable (VideoRendererBackendEvent) -> Void)
    func stopObserving()
}

final class VideoRendererBackend: SampleBufferVideoRenderingBackend, @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer

    private let notificationCenter: NotificationCenter
    private var statusObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        renderer: AVSampleBufferVideoRenderer,
        notificationCenter: NotificationCenter = .default
    ) {
        self.renderer = renderer
        self.notificationCenter = notificationCenter
    }

    deinit {
        stopObserving()
    }

    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }
    var status: AVQueuedSampleBufferRenderingStatus { renderer.status }
    var error: (any Error)? { renderer.error }
    var requiresFlushToResumeDecoding: Bool { renderer.requiresFlushToResumeDecoding }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    ) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        renderer.stopRequestingMediaData()
    }

    func flush(
        removeDisplayedImage: Bool,
        completion: @escaping @Sendable () -> Void
    ) {
        renderer.flush(
            removingDisplayedImage: removeDisplayedImage,
            completionHandler: completion
        )
    }

    func startObserving(_ handler: @escaping @Sendable (VideoRendererBackendEvent) -> Void) {
        stopObserving()
        statusObservation = renderer.observe(\.status, options: [.new]) { renderer, _ in
            guard renderer.status == .failed else { return }
            handler(.failed(renderer.error ?? RendererObservationError.unknown))
        }
        let decodeFailure = notificationCenter.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer,
            queue: nil
        ) { notification in
            let error = notification.userInfo?[
                AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey
            ] as? NSError ?? RendererObservationError.unknown as NSError
            handler(.failed(error))
        }
        let requiresFlush = notificationCenter.addObserver(
            forName: AVSampleBufferVideoRenderer
                .requiresFlushToResumeDecodingDidChangeNotification,
            object: renderer,
            queue: nil
        ) { [weak self] _ in
            guard self?.renderer.requiresFlushToResumeDecoding == true else { return }
            handler(.requiresFlushToResumeDecoding)
        }
        notificationTokens = [decodeFailure, requiresFlush]
    }

    func stopObserving() {
        statusObservation?.invalidate()
        statusObservation = nil
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll(keepingCapacity: false)
    }
}

private enum RendererObservationError: Int, Error {
    case unknown = -1
}
