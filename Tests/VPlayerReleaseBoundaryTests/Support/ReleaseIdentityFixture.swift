// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
@testable import VPlayerPlayback

enum ReleaseIdentityFixture {
    static func lifecycle(using allocator: PlaybackIdentityAllocator,
                          requestID: UUID = UUID()) throws -> OutputLifecycleEpoch {
        let session = PlaybackSessionIdentity(
            sessionID: try allocator.next(in: .session), requestID: requestID)
        let backend = PlaybackBackendIdentity(
            sessionIdentity: session,
            backendGeneration: try allocator.next(in: .backend))
        return OutputLifecycleEpoch(
            backendIdentity: backend,
            outputNonce: try allocator.next(in: .outputLifecycle))
    }

    static func stopContext(using allocator: PlaybackIdentityAllocator) throws
        -> (item: AVPlayerItemInstanceIdentity, issuer: UInt64,
            suspend: OutputSuspendTicket) {
        let lifecycle = try lifecycle(using: allocator)
        let resource = ControlResourceIdentity.backend(lifecycle.backendIdentity)
        let owner = ControlTaskOwnerTicket(
            resourceIdentity: resource,
            nonce: try allocator.next(in: .controlTask))
        let group = ControlTaskGroupTicket(
            resourceIdentity: resource,
            ownerTicket: owner,
            nonce: try allocator.next(in: .controlTask))
        let task = ControlTaskTicket(
            group: group,
            nonce: try allocator.next(in: .controlTask))
        guard let issuer = allocator.issuerIdentity else {
            throw PlaybackIdentityAllocationError.identitySpaceExhausted
        }
        return (
            AVPlayerItemInstanceIdentity(
                outputLifecycleEpoch: lifecycle,
                itemGeneration: try allocator.next(in: .outputItem)),
            issuer,
            OutputSuspendTicket(
                task: task,
                lifecycle: lifecycle,
                priorActivation: nil,
                anchorInstant: 0)
        )
    }
}
