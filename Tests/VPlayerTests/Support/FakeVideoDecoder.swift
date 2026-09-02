// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import VideoToolbox
@testable import VPlayerPlayback

final class FakeVideoDecoder: VideoDecoding, @unchecked Sendable {
    enum Operation: Equatable {
        case transitionConfigure(VideoDecoderTransitionToken, MediaGeneration)
        case transitionDrainAndInvalidate(VideoDecoderTransitionToken)
        case transitionInvalidate(VideoDecoderTransitionToken)
        case decode(UInt64, MediaGeneration, VTDecodeFrameFlags)
    }

    private let lock = NSLock()
    private(set) var operations: [Operation] = []
    private var submissionCompletionSink: (@Sendable (
        UInt64,
        VideoDecoderEventIdentity,
        VideoDecoderSubmissionDisposition
    ) -> Void)?
    private var transitionEventSink: (@Sendable (VideoDecoderEvent) -> Void)?
    private var pendingConfigureIdentities: [
        VideoDecoderTransitionToken: VideoDecoderEventIdentity
    ] = [:]
    private var configuredIdentities: [
        MediaGeneration: VideoDecoderEventIdentity
    ] = [:]
    private var automaticallyCompletesTransitions = false
    private var storedActiveIdentity: VideoDecoderEventIdentity?
    private var storedTransitionRequirement: VideoDecoderTransitionRequirement?
    var decodeError: VideoDecoderFailure?
    var configureTransitionOutcome: VideoDecoderTransitionOutcome = .completed
    var drainTransitionOutcome: VideoDecoderTransitionOutcome = .completed
    var invalidationTransitionOutcome: VideoDecoderTransitionOutcome = .completed

    func transition(_ transition: VideoDecoderTransition) {
        let automaticCompletion: (VideoDecoderTransitionToken, VideoDecoderTransitionOutcome)? =
            lock.withLock {
            let transitionToken: VideoDecoderTransitionToken
            switch transition {
            case let .configure(token, _, generation):
                transitionToken = token
                operations.append(.transitionConfigure(token, generation))
                pendingConfigureIdentities[token] = VideoDecoderEventIdentity(
                    generation: generation,
                    transitionToken: token
                )
                configuredIdentities[generation] = pendingConfigureIdentities[token]
                storedActiveIdentity = nil
            case let .drainAndInvalidate(token):
                transitionToken = token
                operations.append(.transitionDrainAndInvalidate(token))
                storedActiveIdentity = nil
            case let .invalidate(token):
                transitionToken = token
                operations.append(.transitionInvalidate(token))
                storedActiveIdentity = nil
            }
            guard automaticallyCompletesTransitions else { return nil }
            let outcome = switch transition {
            case .configure:
                configureTransitionOutcome
            case .drainAndInvalidate:
                drainTransitionOutcome
            case .invalidate:
                invalidationTransitionOutcome
            }
            return (transitionToken, outcome)
        }
        if let automaticCompletion {
            completeTransition(
                token: automaticCompletion.0,
                outcome: automaticCompletion.1
            )
        }
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws {
        if let decodeError { throw decodeError }
        let completion = lock.withLock {
            operations.append(.decode(accessUnit.id, accessUnit.generation, flags))
            return (submissionCompletionSink, storedActiveIdentity)
        }
        if let sink = completion.0,
           let identity = completion.1,
           identity.generation == accessUnit.generation {
            sink(accessUnit.id, identity, .produced)
        }
    }

    func transitionRequirement(
        for _: CompressedVideoAccessUnit
    ) -> VideoDecoderTransitionRequirement? {
        lock.withLock { storedTransitionRequirement }
    }

    func setTransitionRequirement(_ requirement: VideoDecoderTransitionRequirement?) {
        lock.withLock { storedTransitionRequirement = requirement }
    }

    func setSubmissionCompletionSink(
        _ sink: (@Sendable (
            UInt64,
            VideoDecoderEventIdentity,
            VideoDecoderSubmissionDisposition
        ) -> Void)?
    ) {
        lock.withLock { submissionCompletionSink = sink }
    }

    func setTransitionEventSink(
        automaticallyCompletes: Bool,
        _ sink: (@Sendable (VideoDecoderEvent) -> Void)?
    ) {
        lock.withLock {
            automaticallyCompletesTransitions = automaticallyCompletes
            transitionEventSink = sink
        }
    }

    func setAutomaticallyCompletesTransitions(_ enabled: Bool) {
        lock.withLock { automaticallyCompletesTransitions = enabled }
    }

    func completeTransition(
        token: VideoDecoderTransitionToken,
        outcome: VideoDecoderTransitionOutcome
    ) {
        let sink = lock.withLock { () -> (@Sendable (VideoDecoderEvent) -> Void)? in
            if outcome == .completed, let identity = pendingConfigureIdentities[token] {
                storedActiveIdentity = identity
            }
            pendingConfigureIdentities[token] = nil
            return transitionEventSink
        }
        sink?(.transitionCompleted(token: token, outcome: outcome))
    }

    var latestConfigureTransitionToken: VideoDecoderTransitionToken? {
        lock.withLock {
            operations.reversed().compactMap {
                operation -> VideoDecoderTransitionToken? in
                guard case let .transitionConfigure(token, _) = operation else { return nil }
                return token
            }.first
        }
    }

    var latestInvalidatingTransitionToken: VideoDecoderTransitionToken? {
        lock.withLock {
            operations.reversed().compactMap {
                operation -> VideoDecoderTransitionToken? in
                switch operation {
                case let .transitionDrainAndInvalidate(token),
                     let .transitionInvalidate(token):
                    token
                default:
                    nil
                }
            }.first
        }
    }

    var activeIdentity: VideoDecoderEventIdentity? {
        lock.withLock { storedActiveIdentity }
    }

    func identity(for generation: MediaGeneration) -> VideoDecoderEventIdentity? {
        lock.withLock { configuredIdentities[generation] }
    }

    func decodedAccessUnitIDs(generation: MediaGeneration) -> [UInt64] {
        lock.withLock {
            operations.compactMap { operation in
                guard case let .decode(id, decodedGeneration, _) = operation,
                      decodedGeneration == generation else { return nil }
                return id
            }
        }
    }

    func snapshot() -> [Operation] { lock.withLock { operations } }
}
