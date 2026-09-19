// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct OutputItemGeneration: Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public enum PlaybackPresentation: Sendable {
    case sampleBuffer(PlaybackPresentationContext)
    case avPlayer(AVPlayerPresentationContext)
}

public struct PresentationIdentity: Sendable, Hashable {
    public let sessionIdentity: PlaybackSessionIdentity
    public let backendIdentity: PlaybackBackendIdentity
    public let outputLifecycleEpoch: OutputLifecycleEpoch
    public let itemGeneration: OutputItemGeneration?
    public let presentationNonce: UInt64

    public init(
        sessionIdentity: PlaybackSessionIdentity,
        backendIdentity: PlaybackBackendIdentity,
        outputLifecycleEpoch: OutputLifecycleEpoch,
        itemGeneration: OutputItemGeneration?,
        presentationNonce: UInt64
    ) {
        self.sessionIdentity = sessionIdentity
        self.backendIdentity = backendIdentity
        self.outputLifecycleEpoch = outputLifecycleEpoch
        self.itemGeneration = itemGeneration
        self.presentationNonce = presentationNonce
    }
}

public struct IdentifiedPlaybackPresentation: Sendable {
    public let identity: PresentationIdentity
    public let presentation: PlaybackPresentation

    public init(identity: PresentationIdentity, presentation: PlaybackPresentation) {
        self.identity = identity
        self.presentation = presentation
    }
}

public struct PlaybackPresentationReplacement: Sendable {
    public let subscriptionGeneration: UInt64
    public let revision: UInt64
    public let desired: IdentifiedPlaybackPresentation?

    public init(
        subscriptionGeneration: UInt64,
        revision: UInt64,
        desired: IdentifiedPlaybackPresentation?
    ) {
        self.subscriptionGeneration = subscriptionGeneration
        self.revision = revision
        self.desired = desired
    }
}

public enum PlaybackPresentationMountClaimResult: Sendable, Equatable {
    case claimed(PresentationMountOwnership)
    case stale
    case exhausted
}

public struct PresentationMountOwnership: Sendable, Hashable {
    public let subscriptionGeneration: UInt64
    public let presentationIdentity: PresentationIdentity?
    public let mountNonce: UInt64

    public init(
        subscriptionGeneration: UInt64,
        presentationIdentity: PresentationIdentity?,
        mountNonce: UInt64
    ) {
        self.subscriptionGeneration = subscriptionGeneration
        self.presentationIdentity = presentationIdentity
        self.mountNonce = mountNonce
    }
}
