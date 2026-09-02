// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class PlaybackAudioSessionOwnerTests: XCTestCase {
    func testFirstLeaseConfiguresLongFormMultichannelThenActivates() throws {
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(
            session: session,
            notificationCenter: NotificationCenter()
        )

        _ = try owner.acquire { _, _ in }

        XCTAssertEqual(session.events, [
            .category(.longFormAudio),
            .multichannel(true),
            .active(true),
        ])
    }

    func testLongFormFailureFallsBackToDefaultBeforeActivation() throws {
        let session = RecordingPlaybackAudioSession(
            categoryErrors: [TestAudioSessionFailure.category, nil]
        )
        let owner = PlaybackAudioSessionOwner(
            session: session,
            notificationCenter: NotificationCenter()
        )

        _ = try owner.acquire { _, _ in }

        XCTAssertEqual(session.events, [
            .category(.longFormAudio),
            .category(.default),
            .multichannel(true),
            .active(true),
        ])
    }

    func testReplacementLeaseKeepsSessionActiveUntilLastLeaseIsReleased() throws {
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(
            session: session,
            notificationCenter: NotificationCenter()
        )
        let first = try owner.acquire { _, _ in }
        let replacement = try owner.acquire { _, _ in }

        owner.release(first)
        XCTAssertEqual(owner.activeLeaseCountForTesting, 1)
        XCTAssertEqual(session.events.filter(\.isActivation), [.active(true)])

        owner.release(replacement)
        XCTAssertEqual(owner.activeLeaseCountForTesting, 0)
        XCTAssertEqual(session.events.filter(\.isActivation), [.active(true), .active(false)])
    }

    func testRepeatedStaleLeaseReleaseCannotDeactivateCurrentLease() throws {
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(
            session: session,
            notificationCenter: NotificationCenter()
        )
        let first = try owner.acquire { _, _ in }
        owner.release(first)
        let current = try owner.acquire { _, _ in }

        owner.release(first)

        XCTAssertEqual(owner.activeLeaseCountForTesting, 1)
        XCTAssertEqual(session.events.filter(\.isActivation), [
            .active(true),
            .active(false),
            .active(true),
        ])
        owner.release(current)
    }

    func testInterruptionEventsAreDeliveredOnlyToNewestLiveLease() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        var firstEvents: [PlaybackAudioSessionEvent] = []
        var replacementEvents: [PlaybackAudioSessionEvent] = []
        let first = try owner.acquire { _, event in firstEvents.append(event) }
        let replacement = try owner.acquire { _, event in replacementEvents.append(event) }

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
            ]
        )
        owner.release(first)
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )

        XCTAssertTrue(firstEvents.isEmpty)
        XCTAssertEqual(replacementEvents, [
            .interruptionBegan,
            .interruptionEnded(shouldResume: true),
        ])
        owner.release(replacement)
    }

    func testReleasedNewestLeaseCannotReceiveQueuedOwnerEvent() throws {
        let center = NotificationCenter()
        let delivery = ManualMainActorDelivery()
        let owner = PlaybackAudioSessionOwner(
            session: RecordingPlaybackAudioSession(),
            notificationCenter: center,
            eventDelivery: delivery.schedule
        )
        var events: [PlaybackAudioSessionEvent] = []
        let lease = try owner.acquire { _, event in events.append(event) }
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
            ]
        )

        owner.release(lease)
        delivery.runAll()

        XCTAssertTrue(events.isEmpty)
    }

    func testMediaServicesResetReconfiguresAndReactivatesBeforePublishingEvent() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        var observations: [(PlaybackAudioSessionEvent, [RecordingPlaybackAudioSession.Event])] = []
        let lease = try owner.acquire { _, event in
            observations.append((event, session.events))
        }

        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        XCTAssertEqual(observations.map(\.0), [.mediaServicesWereReset])
        XCTAssertEqual(observations.first?.1, [
            .category(.longFormAudio),
            .multichannel(true),
            .active(true),
            .category(.longFormAudio),
            .multichannel(true),
            .active(true),
        ])
        owner.release(lease)
    }

    func testMediaServicesResetCategoryFailurePublishesOnlySafeFailureStage() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession(categoryErrors: [
            nil,
            TestAudioSessionFailure.category,
            TestAudioSessionFailure.category,
        ])
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        var events: [PlaybackAudioSessionEvent] = []
        let lease = try owner.acquire { _, event in events.append(event) }

        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        XCTAssertEqual(events, [
            .recoveryFailed(stage: .mediaServicesResetConfiguration),
        ])
        owner.release(lease)
    }

    func testMediaServicesResetActivationFailureDoesNotPublishRecoveredEvent() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession(activationErrors: [
            nil,
            TestAudioSessionFailure.activation,
        ])
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        var events: [PlaybackAudioSessionEvent] = []
        let lease = try owner.acquire { _, event in events.append(event) }

        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        XCTAssertEqual(events, [
            .recoveryFailed(stage: .mediaServicesResetActivation),
        ])
        owner.release(lease)
    }

    func testInterruptionEndedReactivatesBeforePublishingResume() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        var observations: [(PlaybackAudioSessionEvent, [RecordingPlaybackAudioSession.Event])] = []
        let lease = try owner.acquire { _, event in
            observations.append((event, session.events))
        }

        postInterruption(.began, center: center)
        postInterruption(.ended, shouldResume: true, center: center)

        XCTAssertEqual(observations.map(\.0), [
            .interruptionBegan,
            .interruptionEnded(shouldResume: true),
        ])
        XCTAssertEqual(observations.last?.1.filter(\.isActivation), [
            .active(true),
            .active(true),
        ])
        owner.release(lease)
    }

    func testInterruptionReactivationFailurePublishesSafeFailureInsteadOfResume() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession(activationErrors: [
            nil,
            TestAudioSessionFailure.activation,
        ])
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        var events: [PlaybackAudioSessionEvent] = []
        let lease = try owner.acquire { _, event in events.append(event) }

        postInterruption(.began, center: center)
        postInterruption(.ended, shouldResume: true, center: center)

        XCTAssertEqual(events, [
            .interruptionBegan,
            .recoveryFailed(stage: .interruptionReactivation),
        ])
        owner.release(lease)
    }

    func testExplicitResumeActivatesOnlyNewestLeaseOutsidePhysicalInterruption() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        var firstEvents: [PlaybackAudioSessionEvent] = []
        var replacementEvents: [PlaybackAudioSessionEvent] = []
        let first = try owner.acquire { _, event in firstEvents.append(event) }
        let replacement = try owner.acquire { _, event in replacementEvents.append(event) }

        owner.requestResume(for: first)
        postInterruption(.began, center: center)
        owner.requestResume(for: replacement)
        postInterruption(.ended, shouldResume: false, center: center)
        owner.requestResume(for: replacement)

        XCTAssertEqual(session.events.filter(\.isActivation), [
            .active(true),
            .active(true),
        ])
        XCTAssertEqual(firstEvents, [])
        XCTAssertEqual(replacementEvents, [
            .interruptionBegan,
            .interruptionEnded(shouldResume: false),
            .explicitResumeSucceeded,
        ])
        owner.release(first)
        owner.release(replacement)
    }

    func testExplicitResumeActivationFailurePublishesSafeRecoveryFailure() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession(activationErrors: [
            nil,
            TestAudioSessionFailure.activation,
        ])
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        var events: [PlaybackAudioSessionEvent] = []
        let lease = try owner.acquire { _, event in events.append(event) }

        postInterruption(.began, center: center)
        postInterruption(.ended, shouldResume: false, center: center)
        owner.requestResume(for: lease)

        XCTAssertEqual(events, [
            .interruptionBegan,
            .interruptionEnded(shouldResume: false),
            .recoveryFailed(stage: .interruptionReactivation),
        ])
        owner.release(lease)
    }

    func testLeaseAcquiredDuringInterruptionInheritsStateAndFencesQueuedOldEvent() throws {
        let center = NotificationCenter()
        let delivery = ManualMainActorDelivery()
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(
            session: session,
            notificationCenter: center,
            eventDelivery: delivery.schedule
        )
        var firstEvents: [PlaybackAudioSessionEvent] = []
        var replacementEvents: [PlaybackAudioSessionEvent] = []
        let first = try owner.acquire { _, event in firstEvents.append(event) }
        postInterruption(.began, center: center)

        let replacement = try owner.acquire { _, event in replacementEvents.append(event) }
        owner.release(first)
        delivery.runAll()

        XCTAssertTrue(replacement.isInterruptedAtAcquisition)
        XCTAssertTrue(firstEvents.isEmpty)
        XCTAssertTrue(replacementEvents.isEmpty)

        postInterruption(.ended, shouldResume: true, center: center)
        delivery.runAll()
        XCTAssertEqual(replacementEvents, [.interruptionEnded(shouldResume: true)])
        XCTAssertEqual(session.events.filter(\.isActivation), [.active(true), .active(true)])
        owner.release(replacement)
    }

    func testNewLeaseAfterNonResumableInterruptionReactivatesInactiveSession() throws {
        let center = NotificationCenter()
        let session = RecordingPlaybackAudioSession()
        let owner = PlaybackAudioSessionOwner(session: session, notificationCenter: center)
        let first = try owner.acquire { _, _ in }
        postInterruption(.began, center: center)
        postInterruption(.ended, shouldResume: false, center: center)

        let replacement = try owner.acquire { _, _ in }

        XCTAssertFalse(replacement.isInterruptedAtAcquisition)
        XCTAssertEqual(session.events.filter(\.isActivation), [.active(true), .active(true)])
        owner.release(first)
        owner.release(replacement)
    }

    func testFailureDiagnosticContainsOnlyBoundedStageDomainAndCode() throws {
        let sensitiveMarker = "sensitive-marker"
        let error = NSError(
            domain: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01234567 é?/TRUNCATED",
            code: Int.max,
            userInfo: [NSLocalizedDescriptionKey: sensitiveMarker]
        )
        let session = RecordingPlaybackAudioSession(categoryErrors: [error, nil])
        var diagnostics: [PlaybackAudioSessionDiagnostic] = []
        let owner = PlaybackAudioSessionOwner(
            session: session,
            notificationCenter: NotificationCenter(),
            reportFailure: { diagnostics.append($0) }
        )

        _ = try owner.acquire { _, _ in }

        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostic.stage, .longFormAudioCategory)
        XCTAssertEqual(
            diagnostic.errorDomain,
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01234567____"
        )
        XCTAssertEqual(diagnostic.errorCode, 2_147_483_647)
        XCTAssertEqual(diagnostic.errorDomain.utf8.count, 64)
        XCTAssertFalse(String(describing: diagnostic).contains(sensitiveMarker))
    }

    private func postInterruption(
        _ type: AVAudioSession.InterruptionType,
        shouldResume: Bool = false,
        center: NotificationCenter
    ) {
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: type.rawValue,
                AVAudioSessionInterruptionOptionKey: shouldResume
                    ? AVAudioSession.InterruptionOptions.shouldResume.rawValue
                    : 0,
            ]
        )
    }
}

@MainActor
private final class RecordingPlaybackAudioSession: PlaybackAudioSessionApplying {
    enum Event: Equatable {
        case category(AVAudioSession.RouteSharingPolicy)
        case multichannel(Bool)
        case active(Bool)

        var isActivation: Bool {
            if case .active = self { return true }
            return false
        }
    }

    private var categoryErrors: [Error?]
    private let multichannelError: Error?
    private var activationErrors: [Error?]
    private(set) var events: [Event] = []

    init(
        categoryErrors: [Error?] = [],
        multichannelError: Error? = nil,
        activationErrors: [Error?] = []
    ) {
        self.categoryErrors = categoryErrors
        self.multichannelError = multichannelError
        self.activationErrors = activationErrors
    }

    func setPlaybackCategory(policy: AVAudioSession.RouteSharingPolicy) throws {
        events.append(.category(policy))
        if !categoryErrors.isEmpty, let error = categoryErrors.removeFirst() { throw error }
    }

    func setSupportsMultichannelContent(_ enabled: Bool) throws {
        events.append(.multichannel(enabled))
        if let multichannelError { throw multichannelError }
    }

    func setActive(_ active: Bool) throws {
        events.append(.active(active))
        if !activationErrors.isEmpty, let error = activationErrors.removeFirst() { throw error }
    }
}

@MainActor
private final class ManualMainActorDelivery {
    private var operations: [@MainActor () -> Void] = []

    func schedule(_ operation: @escaping @MainActor () -> Void) {
        operations.append(operation)
    }

    func runAll() {
        let pending = operations
        operations.removeAll(keepingCapacity: true)
        for operation in pending { operation() }
    }
}

private enum TestAudioSessionFailure: Error {
    case category
    case activation
}
