// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation

final class AudioOutputRouteMonitor: AudioRouteMonitoring, @unchecked Sendable {
    typealias SnapshotProvider = @Sendable () -> [AVAudioSession.Port]

    private enum PendingDelivery: Sendable {
        case initial
        case routeChange(AudioRouteChangeReason)
    }

    private let executor: PlaybackSerialExecutor
    private let notificationCenter: NotificationCenter
    private let snapshotProvider: SnapshotProvider
    private let initialDrainBoundaryHook: @Sendable () -> Void
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var eventHandler: (@Sendable (AudioOutputRouteSnapshot) -> Void)?
    private var nextLifecycle: UInt64? = 1
    private var activeLifecycle: UInt64 = 0
    private var revision: UInt64 = 0
    private var initialDeliveryQueued = false
    private var deliveryPumpScheduled = false
    private var preInitialReasons: [AudioRouteChangeReason] = []
    private var pendingDeliveries: [PendingDelivery] = []

    init(
        executor: PlaybackSerialExecutor,
        notificationCenter: NotificationCenter = .default,
        snapshotProvider: @escaping SnapshotProvider = {
            AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        },
        initialDrainBoundaryHook: @escaping @Sendable () -> Void = {}
    ) {
        self.executor = executor
        self.notificationCenter = notificationCenter
        self.snapshotProvider = snapshotProvider
        self.initialDrainBoundaryHook = initialDrainBoundaryHook
    }

    deinit {
        stop()
    }

    func start(_ handler: @escaping @Sendable (AudioOutputRouteSnapshot) -> Void) {
        stop()
        let lifecycle = withLock { () -> UInt64 in
            guard let value = nextLifecycle else { return 0 }
            nextLifecycle = value == UInt64.max ? nil : value + 1
            activeLifecycle = value
            revision = 0
            initialDeliveryQueued = false
            deliveryPumpScheduled = false
            preInitialReasons.removeAll(keepingCapacity: true)
            pendingDeliveries.removeAll(keepingCapacity: true)
            eventHandler = handler
            return value
        }
        guard lifecycle != 0 else { return }
        observer = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
            let reason = Self.reason(from: reasonValue)
            self?.enqueueRouteChange(reason: reason, for: lifecycle)
        }
        enqueueInitialRoute(for: lifecycle)
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        withLock {
            activeLifecycle = 0
            initialDeliveryQueued = false
            deliveryPumpScheduled = false
            preInitialReasons.removeAll(keepingCapacity: true)
            pendingDeliveries.removeAll(keepingCapacity: true)
            eventHandler = nil
        }
    }

    private static func category(from ports: [AVAudioSession.Port]) -> AudioOutputRouteCategory {
        if ports.isEmpty { return .none }
        if ports.contains(AVAudioSession.Port.HDMI) { return .hdmi }
        if ports.contains(.airPlay) { return .airPlay }
        return .other
    }

    private static func reason(from value: Any?) -> AudioRouteChangeReason {
        let rawValue: UInt
        switch value {
        case let value as UInt:
            rawValue = value
        case let value as NSNumber:
            rawValue = value.uintValue
        default:
            return .unknown
        }
        switch AVAudioSession.RouteChangeReason(rawValue: rawValue) {
        case .newDeviceAvailable: return .newDeviceAvailable
        case .oldDeviceUnavailable: return .oldDeviceUnavailable
        case .categoryChange: return .categoryChange
        case .override: return .override
        case .wakeFromSleep: return .wakeFromSleep
        case .noSuitableRouteForCategory: return .noSuitableRoute
        case .routeConfigurationChange: return .routeConfigurationChange
        case .unknown, .none: return .unknown
        @unknown default: return .unknown
        }
    }

    private func enqueueInitialRoute(for lifecycle: UInt64) {
        let shouldSchedule = withLock { () -> Bool in
            guard activeLifecycle == lifecycle else { return false }
            pendingDeliveries.append(.initial)
            pendingDeliveries.append(contentsOf: preInitialReasons.map(PendingDelivery.routeChange))
            preInitialReasons.removeAll(keepingCapacity: true)
            initialDeliveryQueued = true
            return claimDeliveryPumpLocked()
        }
        if shouldSchedule {
            executor.submit { [weak self] in
                self?.drainDeliveries(for: lifecycle)
            }
        }
        initialDrainBoundaryHook()
    }

    private func enqueueRouteChange(
        reason: AudioRouteChangeReason,
        for lifecycle: UInt64
    ) {
        let shouldSchedule = withLock { () -> Bool in
            guard activeLifecycle == lifecycle else { return false }
            guard initialDeliveryQueued else {
                preInitialReasons.append(reason)
                return false
            }
            pendingDeliveries.append(.routeChange(reason))
            return claimDeliveryPumpLocked()
        }
        guard shouldSchedule else { return }
        executor.submit { [weak self] in
            self?.drainDeliveries(for: lifecycle)
        }
    }

    private func claimDeliveryPumpLocked() -> Bool {
        guard !deliveryPumpScheduled else { return false }
        deliveryPumpScheduled = true
        return true
    }

    private func drainDeliveries(for lifecycle: UInt64) {
        while let delivery = nextDelivery(for: lifecycle) {
            switch delivery {
            case .initial:
                deliverInitialRoute(for: lifecycle)
            case let .routeChange(reason):
                deliverCurrentRoute(reason: reason, for: lifecycle)
            }
        }
    }

    private func nextDelivery(for lifecycle: UInt64) -> PendingDelivery? {
        withLock {
            guard activeLifecycle == lifecycle else { return nil }
            guard !pendingDeliveries.isEmpty else {
                deliveryPumpScheduled = false
                return nil
            }
            return pendingDeliveries.removeFirst()
        }
    }

    private func deliverInitialRoute(for lifecycle: UInt64) {
        let category = Self.category(from: snapshotProvider())
        let copiedHandler = withLock {
            activeLifecycle == lifecycle ? eventHandler : nil
        }
        copiedHandler?(AudioOutputRouteSnapshot(
            category: category,
            reason: .initial,
            revision: 0
        ))
    }

    private func deliverCurrentRoute(
        reason: AudioRouteChangeReason,
        for lifecycle: UInt64
    ) {
        let category = Self.category(from: snapshotProvider())
        let delivery = withLock { () -> (
            @Sendable (AudioOutputRouteSnapshot) -> Void,
            UInt64
        )? in
            guard activeLifecycle == lifecycle,
                  let eventHandler,
                  revision < UInt64.max else { return nil }
            revision += 1
            return (eventHandler, revision)
        }
        guard let (handler, revision) = delivery else { return }
        handler(AudioOutputRouteSnapshot(
            category: category,
            reason: reason,
            revision: revision
        ))
    }

    @discardableResult
    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
