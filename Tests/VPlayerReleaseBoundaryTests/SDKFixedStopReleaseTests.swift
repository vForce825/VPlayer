// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import XCTest
@testable import VPlayerPlayback

@MainActor
final class SDKFixedStopReleaseTests: XCTestCase {
    func testFixedStopOriginalFailureReplay() async throws {
        for failure in [AVPlayerItemCoordinatorFailure.staleIdentity,
                        .directPauseNotConfirmed, .itemFailed] {
            let allocator = PlaybackIdentityAllocator()
            let context = try ReleaseIdentityFixture.stopContext(using: allocator)
            let task = OutputPlayerStopTask(
                item: context.item,
                registryIssuerIdentity: context.issuer,
                suspendTicket: context.suspend,
                closeClaim: nil)
            task.complete(.failure(failure))
            task.complete(.failure(.capacityExceeded))

            for _ in 0..<2 {
                do {
                    _ = try await task.value(
                        registryIssuerIdentity: context.issuer,
                        suspendTicket: context.suspend,
                        closeClaim: nil)
                    XCTFail("固定槽必须重放第一次失败")
                } catch {
                    XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, failure)
                }
            }
            do {
                _ = try await task.value(
                    registryIssuerIdentity: context.issuer + 1,
                    suspendTicket: context.suspend,
                    closeClaim: nil)
                XCTFail("外来 issuer 不得读取终态")
            } catch {
                XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure,
                               .operationInFlight)
            }

            let text = "stopIdentity=\(ObjectIdentifier(task)), "
                + "stopMalloc=\(malloc_size(Unmanaged.passUnretained(task).toOpaque())), "
                + "failureStride=\(MemoryLayout<AVPlayerItemCoordinatorFailure>.stride), "
                + "ownedErrorReservation=\(ControlTaskRegistry.ownedControlAllocationReservation.fixedErrorReservation)"
            let attachment = XCTAttachment(string: text)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
