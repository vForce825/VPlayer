// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import OSLog

@MainActor
protocol AudioSessionApplying: AnyObject {
    func setPlaybackCategory(policy: AVAudioSession.RouteSharingPolicy) throws
    func setSupportsMultichannelContent(_ enabled: Bool) throws
}

struct AudioSessionConfigurationDiagnostic: Equatable {
    enum Stage: String, Equatable {
        case longFormAudioCategory
        case defaultCategory
        case multichannelContent
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
        let sanitizedScalars = domain.unicodeScalars.prefix(64).map { scalar in
            switch scalar.value {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                return Character(scalar)
            default:
                return "_"
            }
        }
        let sanitized = String(sanitizedScalars)
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}

@MainActor
final class SystemAudioSessionConfigurator {
    typealias FailureReporter = @MainActor (AudioSessionConfigurationDiagnostic) -> Void

    private let session: any AudioSessionApplying
    private let reportFailure: FailureReporter
    private var didAttemptConfiguration = false

    convenience init() {
        self.init(session: SystemAudioSessionAdapter(session: .sharedInstance()))
    }

    init(
        session: any AudioSessionApplying,
        reportFailure: @escaping FailureReporter = { diagnostic in
            audioSessionLogger.error(
                "configuration failed stage=\(diagnostic.stage.rawValue, privacy: .public) domain=\(diagnostic.errorDomain, privacy: .public) code=\(diagnostic.errorCode, privacy: .public)"
            )
        }
    ) {
        self.session = session
        self.reportFailure = reportFailure
    }

    func configureOnce() {
        guard !didAttemptConfiguration else { return }
        didAttemptConfiguration = true

        do {
            try session.setPlaybackCategory(policy: .longFormAudio)
        } catch {
            report(error, at: .longFormAudioCategory)
            do {
                try session.setPlaybackCategory(policy: .default)
            } catch {
                report(error, at: .defaultCategory)
                return
            }
        }

        do {
            try session.setSupportsMultichannelContent(true)
        } catch {
            report(error, at: .multichannelContent)
        }
    }

    private func report(_ error: Error, at stage: AudioSessionConfigurationDiagnostic.Stage) {
        let nsError = error as NSError
        reportFailure(AudioSessionConfigurationDiagnostic(
            stage: stage,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        ))
    }
}

@MainActor
private final class SystemAudioSessionAdapter: AudioSessionApplying {
    private let session: AVAudioSession

    init(session: AVAudioSession) {
        self.session = session
    }

    func setPlaybackCategory(policy: AVAudioSession.RouteSharingPolicy) throws {
        try session.setCategory(
            .playback,
            mode: .moviePlayback,
            policy: policy
        )
    }

    func setSupportsMultichannelContent(_ enabled: Bool) throws {
        try session.setSupportsMultichannelContent(enabled)
    }
}

private let audioSessionLogger = Logger(
    subsystem: "com.vforce.vplayer",
    category: "AudioSession"
)
