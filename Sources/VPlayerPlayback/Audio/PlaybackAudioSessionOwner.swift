// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation
import OSLog

private final class PlaybackAudioSessionNotificationToken: @unchecked Sendable {
    private let value: NSObjectProtocol

    init(_ value: NSObjectProtocol) {
        self.value = value
    }

    func remove(from notificationCenter: NotificationCenter) {
        notificationCenter.removeObserver(value)
    }
}

public struct PlaybackAudioSessionLease: Hashable, Sendable {
    public let id: UInt64
    public let generation: UInt64
    public let isInterruptedAtAcquisition: Bool

    public init(
        id: UInt64,
        generation: UInt64,
        isInterruptedAtAcquisition: Bool = false
    ) {
        self.id = id
        self.generation = generation
        self.isInterruptedAtAcquisition = isInterruptedAtAcquisition
    }
}

public enum PlaybackAudioSessionRecoveryFailureStage: String, Sendable, Equatable {
    case mediaServicesResetConfiguration
    case mediaServicesResetActivation
    case interruptionReactivation
}

public enum PlaybackAudioSessionEvent: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case explicitResumeSucceeded
    case mediaServicesWereReset
    case recoveryFailed(stage: PlaybackAudioSessionRecoveryFailureStage)
}

struct PlaybackAudioSessionDiagnostic: Equatable {
    enum Stage: String, Equatable {
        case longFormAudioCategory
        case defaultCategory
        case multichannelContent
        case activation
        case deactivation
        case mediaServicesReset
    }

    let stage: Stage
    let errorDomain: String
    let errorCode: Int

    init(stage: Stage, errorDomain: String, errorCode: Int) {
        self.stage = stage
        self.errorDomain = Self.sanitize(domain: errorDomain)
        self.errorCode = min(Int(Int32.max), max(Int(Int32.min), errorCode))
    }

    private static func sanitize(domain: String) -> String {
        let scalars = domain.unicodeScalars.prefix(64).map { scalar in
            switch scalar.value {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                return Character(scalar)
            default:
                return "_"
            }
        }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}

@MainActor
protocol PlaybackAudioSessionApplying: AnyObject {
    func setPlaybackCategory(policy: AVAudioSession.RouteSharingPolicy) throws
    func setSupportsMultichannelContent(_ enabled: Bool) throws
    func setActive(_ active: Bool) throws
}

protocol PlaybackAudioSessionOwning: AnyObject, Sendable {
    @MainActor
    func acquire(
        eventHandler: @escaping @MainActor @Sendable (
            PlaybackAudioSessionLease,
            PlaybackAudioSessionEvent
        ) -> Void
    ) throws -> PlaybackAudioSessionLease

    @MainActor
    func release(_ lease: PlaybackAudioSessionLease)

    @MainActor
    func requestResume(for lease: PlaybackAudioSessionLease) -> Bool
}

@MainActor
final class PlaybackAudioSessionOwner: PlaybackAudioSessionOwning {
    typealias FailureReporter = @MainActor (PlaybackAudioSessionDiagnostic) -> Void
    typealias EventDelivery = @MainActor (@escaping @MainActor () -> Void) -> Void
    typealias EventHandler = @MainActor @Sendable (
        PlaybackAudioSessionLease,
        PlaybackAudioSessionEvent
    ) -> Void

    private let session: any PlaybackAudioSessionApplying
    private let notificationCenter: NotificationCenter
    private let reportFailure: FailureReporter
    private let eventDelivery: EventDelivery
    private var interruptionObserver: PlaybackAudioSessionNotificationToken?
    private var mediaResetObserver: PlaybackAudioSessionNotificationToken?
    private var handlers: [PlaybackAudioSessionLease: EventHandler] = [:]
    private var nextLeaseID: UInt64 = 1
    private var nextLeaseGeneration: UInt64 = 1
    private var isConfigured = false
    private var isInterrupted = false
    private var sessionIsActive = false

    convenience init() {
        self.init(
            session: SystemPlaybackAudioSessionAdapter(session: .sharedInstance()),
            notificationCenter: .default
        )
    }

    init(
        session: any PlaybackAudioSessionApplying,
        notificationCenter: NotificationCenter,
        eventDelivery: @escaping EventDelivery = { operation in operation() },
        reportFailure: @escaping FailureReporter = { diagnostic in
            playbackAudioSessionLogger.error(
                "operation failed stage=\(diagnostic.stage.rawValue, privacy: .public) domain=\(diagnostic.errorDomain, privacy: .public) code=\(diagnostic.errorCode, privacy: .public)"
            )
        }
    ) {
        self.session = session
        self.notificationCenter = notificationCenter
        self.eventDelivery = eventDelivery
        self.reportFailure = reportFailure
        observeSessionEvents()
    }

    deinit {
        interruptionObserver?.remove(from: notificationCenter)
        mediaResetObserver?.remove(from: notificationCenter)
    }

    func acquire(
        eventHandler: @escaping EventHandler
    ) throws -> PlaybackAudioSessionLease {
        if !isConfigured {
            try configureSession()
        }
        if !isInterrupted, !sessionIsActive {
            do {
                try session.setActive(true)
                sessionIsActive = true
            } catch {
                report(error, at: .activation)
                throw error
            }
        }

        let lease = PlaybackAudioSessionLease(
            id: nextLeaseID,
            generation: nextLeaseGeneration,
            isInterruptedAtAcquisition: isInterrupted
        )
        nextLeaseID &+= 1
        nextLeaseGeneration &+= 1
        handlers[lease] = eventHandler
        return lease
    }

    func release(_ lease: PlaybackAudioSessionLease) {
        guard handlers.removeValue(forKey: lease) != nil else { return }
        guard handlers.isEmpty else { return }
        sessionIsActive = false
        do {
            try session.setActive(false)
        } catch {
            report(error, at: .deactivation)
        }
    }

    @discardableResult
    func requestResume(for lease: PlaybackAudioSessionLease) -> Bool {
        guard newestLiveLease() == lease,
              handlers[lease] != nil,
              !isInterrupted else { return false }
        sessionIsActive = false
        do {
            try session.setActive(true)
            sessionIsActive = true
            enqueue(.explicitResumeSucceeded)
        } catch {
            report(error, at: .activation)
            enqueue(.recoveryFailed(stage: .interruptionReactivation))
        }
        return true
    }

    var activeLeaseCountForTesting: Int { handlers.count }

    private func configureSession() throws {
        do {
            try session.setPlaybackCategory(policy: .longFormAudio)
        } catch {
            report(error, at: .longFormAudioCategory)
            do {
                try session.setPlaybackCategory(policy: .default)
            } catch {
                report(error, at: .defaultCategory)
                throw error
            }
        }

        do {
            try session.setSupportsMultichannelContent(true)
        } catch {
            report(error, at: .multichannelContent)
        }
        isConfigured = true
    }

    private func observeSessionEvents() {
        interruptionObserver = PlaybackAudioSessionNotificationToken(
            notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawType = Self.unsignedValue(
                notification.userInfo?[AVAudioSessionInterruptionTypeKey]
            )
            let rawOptions = Self.unsignedValue(
                notification.userInfo?[AVAudioSessionInterruptionOptionKey]
            ) ?? 0
            MainActor.assumeIsolated {
                self?.receiveInterruption(type: rawType, options: rawOptions)
            }
        })
        mediaResetObserver = PlaybackAudioSessionNotificationToken(
            notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.receiveMediaServicesReset()
            }
        })
    }

    private func receiveInterruption(type: UInt?, options: UInt) {
        switch type.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
        case .began:
            isInterrupted = true
            sessionIsActive = false
            enqueue(.interruptionBegan)
        case .ended:
            guard isInterrupted else { return }
            isInterrupted = false
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options)
                .contains(.shouldResume)
            if shouldResume, !handlers.isEmpty {
                do {
                    try session.setActive(true)
                    sessionIsActive = true
                } catch {
                    report(error, at: .activation)
                    enqueue(.recoveryFailed(stage: .interruptionReactivation))
                    return
                }
            }
            enqueue(.interruptionEnded(shouldResume: shouldResume))
        case .none:
            break
        @unknown default:
            break
        }
    }

    private func receiveMediaServicesReset() {
        isConfigured = false
        isInterrupted = false
        sessionIsActive = false
        if !handlers.isEmpty {
            do {
                try configureSession()
            } catch {
                report(error, at: .mediaServicesReset)
                enqueue(.recoveryFailed(stage: .mediaServicesResetConfiguration))
                return
            }
            do {
                try session.setActive(true)
                sessionIsActive = true
            } catch {
                report(error, at: .mediaServicesReset)
                enqueue(.recoveryFailed(stage: .mediaServicesResetActivation))
                return
            }
        }
        enqueue(.mediaServicesWereReset)
    }

    private func enqueue(_ event: PlaybackAudioSessionEvent) {
        guard let lease = newestLiveLease() else { return }
        eventDelivery { [weak self] in
            guard let self,
                  self.newestLiveLease() == lease,
                  let handler = self.handlers[lease] else { return }
            handler(lease, event)
        }
    }

    private func newestLiveLease() -> PlaybackAudioSessionLease? {
        handlers.keys.max { lhs, rhs in lhs.generation < rhs.generation }
    }

    private func report(_ error: Error, at stage: PlaybackAudioSessionDiagnostic.Stage) {
        let nsError = error as NSError
        reportFailure(PlaybackAudioSessionDiagnostic(
            stage: stage,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        ))
    }

    nonisolated private static func unsignedValue(_ value: Any?) -> UInt? {
        switch value {
        case let value as UInt:
            value
        case let value as NSNumber:
            value.uintValue
        default:
            nil
        }
    }
}

@MainActor
private final class SystemPlaybackAudioSessionAdapter: PlaybackAudioSessionApplying {
    private let session: AVAudioSession

    init(session: AVAudioSession) {
        self.session = session
    }

    func setPlaybackCategory(policy: AVAudioSession.RouteSharingPolicy) throws {
        try session.setCategory(.playback, mode: .moviePlayback, policy: policy)
    }

    func setSupportsMultichannelContent(_ enabled: Bool) throws {
        try session.setSupportsMultichannelContent(enabled)
    }

    func setActive(_ active: Bool) throws {
        try session.setActive(active)
    }
}

private let playbackAudioSessionLogger = Logger(
    subsystem: "com.vforce.vplayer",
    category: "AudioSession"
)
