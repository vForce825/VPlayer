// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation

final class AudioOutputRouteMonitor: AudioRouteMonitoring, @unchecked Sendable {
    typealias SnapshotProvider = @Sendable () -> [AVAudioSession.Port]

    private let executor: PlaybackSerialExecutor
    private let notificationCenter: NotificationCenter
    private let snapshotProvider: SnapshotProvider
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var eventHandler: (@Sendable (AudioOutputCategory) -> Void)?
    private var nextLifecycle: UInt64? = 1
    private var activeLifecycle: UInt64 = 0

    init(
        executor: PlaybackSerialExecutor,
        notificationCenter: NotificationCenter = .default,
        snapshotProvider: @escaping SnapshotProvider = {
            AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        }
    ) {
        self.executor = executor
        self.notificationCenter = notificationCenter
        self.snapshotProvider = snapshotProvider
    }

    deinit {
        stop()
    }

    func start(_ handler: @escaping @Sendable (AudioOutputCategory) -> Void) {
        stop()
        let lifecycle = withLock { () -> UInt64 in
            guard let value = nextLifecycle else { return 0 }
            nextLifecycle = value == UInt64.max ? nil : value + 1
            activeLifecycle = value
            eventHandler = handler
            return value
        }
        guard lifecycle != 0 else { return }
        let executor = executor
        observer = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            executor.submit { [weak self] in
                self?.deliverCurrentRoute(for: lifecycle)
            }
        }
        executor.submit { [weak self] in
            self?.deliverCurrentRoute(for: lifecycle)
        }
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        withLock {
            activeLifecycle = 0
            eventHandler = nil
        }
    }

    private static func category(from ports: [AVAudioSession.Port]) -> AudioOutputCategory {
        if ports.isEmpty { return .none }
        if ports.contains(AVAudioSession.Port.HDMI) { return .hdmi }
        if ports.contains(.airPlay) { return .airPlay }
        return .other
    }

    private func deliverCurrentRoute(for lifecycle: UInt64) {
        let category = Self.category(from: snapshotProvider())
        let copiedHandler = withLock {
            activeLifecycle == lifecycle ? eventHandler : nil
        }
        copiedHandler?(category)
    }

    @discardableResult
    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
