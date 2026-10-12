// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation

/// 只能由本文件注册的原生 EOS 通知签发；不以暂停、时长或窗口边界构造。
struct NativeHLSObservedEnd: Sendable {
    let physicalItem: ObjectIdentifier
    fileprivate init(physicalItem: ObjectIdentifier) { self.physicalItem = physicalItem }
}

/// Fixed event slots and one joined worker; callbacks carry no source URL or
/// format payload. The worker loads a fresh consistent selected-item snapshot.
final class NativeHLSObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false, pending = false, failed = false
    private var work: Task<Void, Never>?
    private var observedEnd = false
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private let handler: @MainActor @Sendable (Bool, NativeHLSObservedEnd?) async -> Void
    private let physicalItem: ObjectIdentifier
    private let retention: HLSApplicationLifetimeCharge
    private let selectionRevision: NativeHLSSelectionRevision

    @MainActor init(item: AVPlayerItem, driver: SystemAVPlayerDriver,
                    handler: @escaping @MainActor @Sendable (Bool, NativeHLSObservedEnd?) async -> Void) throws {
        physicalItem = ObjectIdentifier(item)
        retention = try HLSApplicationLifetimeCharge(bytes: 16 * 1_024)
        selectionRevision = driver.nativeSelectionRevision
        self.handler = handler
        // Shared by all registered SDK closures. Driver retirement joins its last
        // physical alias after KVO/notification removal and this worker's return.
        let callback = try driver.reserveSDKCallbackLease(.nativeObservation)
        observations = [
            item.observe(\.duration, options: [.new]) { [weak self] _, _ in callback.assertRegistered(); self?.offer(failed: false, reason: .duration) },
            item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in callback.assertRegistered(); self?.offer(failed: false, reason: .presentationSize) },
            item.observe(\.tracks, options: [.new]) { [weak self] _, _ in callback.assertRegistered(); self?.offer(failed: false, reason: .tracks) },
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                callback.assertRegistered()
                #if DEBUG
                if item.status == .failed {
                    let error = item.error as NSError?
                    print("NATIVE_HLS_SDK_FAILURE signal=status error-domain=\(String((error?.domain ?? "none").prefix(96))) error-code=\(error?.code ?? 0)")
                }
                #endif
                self?.offer(failed: item.status == .failed, reason: .status)
            }
        ]
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: nil) { [weak self] _ in
                callback.assertRegistered()
                self?.offerSignal(failed: false, reason: .privateEOS, ended: true)
            })
        for name in [AVPlayerItem.mediaSelectionDidChangeNotification, AVPlayerItem.newAccessLogEntryNotification,
                     AVPlayerItem.newErrorLogEntryNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            let failure = name == AVPlayerItem.failedToPlayToEndTimeNotification
            let reason: NativeHLSSelectionInvalidationReason
            switch name {
            case AVPlayerItem.mediaSelectionDidChangeNotification: reason = .mediaSelection
            case AVPlayerItem.newAccessLogEntryNotification: reason = .accessLog
            case AVPlayerItem.newErrorLogEntryNotification: reason = .errorLog
            default: reason = .failedToEnd
            }
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: nil) { [weak self] notification in
                callback.assertRegistered()
                #if DEBUG
                if failure {
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                    print("NATIVE_HLS_SDK_FAILURE signal=failed-to-end error-domain=\(String((error?.domain ?? "none").prefix(96))) error-code=\(error?.code ?? 0)")
                }
                #endif
                self?.offer(failed: failure, reason: reason)
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayer.eligibleForHDRPlaybackDidChangeNotification,
            object: nil, queue: nil) { [weak self] _ in callback.assertRegistered(); self?.offer(failed: false, reason: .hdrEligibility) })
        selectionRevision.installEndRefresh(owner: ObjectIdentifier(self)) { [weak self] in self?.offer(failed: false, reason: .privateEOSRefresh) }
    }
    func offer(failed: Bool, reason: NativeHLSSelectionInvalidationReason = .unspecified) {
        offerSignal(failed: failed, reason: reason, ended: false)
    }
    private func offerSignal(failed: Bool, reason: NativeHLSSelectionInvalidationReason, ended: Bool) {
        lock.withLock {
            guard !closed else { return }
            // Revoke cached timing synchronously, before the joined worker can
            // suspend in SDK loads. Even same-object format changes need a new seal.
            selectionRevision.invalidate(reason: reason)
            pending = true; self.failed = self.failed || failed
            observedEnd = observedEnd || ended
            guard work == nil else { return }
            work = Task { @MainActor [self] in
                while let signal = take() {
                    await handler(signal.0, signal.1 ? NativeHLSObservedEnd(physicalItem: physicalItem) : nil)
                }
            }
        }
    }
    private func take() -> (Bool, Bool)? {
        lock.withLock {
            guard !closed, pending else { work = nil; return nil }
            let value = (failed, observedEnd); failed = false; pending = false; observedEnd = false
            return value
        }
    }
    @MainActor func close() async {
        let current = lock.withLock { () -> Task<Void, Never>? in closed = true; pending = false; return work }
        selectionRevision.clearEndRefresh(owner: ObjectIdentifier(self))
        for observation in observations { observation.invalidate() }
        observations.removeAll()
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
        notifications.removeAll()
        current?.cancel(); await current?.value
    }
}

final class NativeHLSMetadataStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlaybackPreparedMediaInformation?
    func publish(_ value: PlaybackPreparedMediaInformation?) { lock.withLock { self.value = value } }
    func snapshot(for lifecycle: OutputLifecycleEpoch) -> PlaybackPreparedMediaInformation? {
        lock.withLock { value?.lifecycle == lifecycle ? value : nil }
    }
}
