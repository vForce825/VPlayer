// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class PlaybackIdentityAllocatorTests: XCTestCase {
    func testSingleNamespaceSeedLeavesConfigurationAndOtherDomainsIndependentUntilStickyExhaustion() throws {
        for seeded in PlaybackIdentityNamespace.allCases {
            let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1, initialNamespace: seeded)
            for other in PlaybackIdentityNamespace.allCases where other != seeded {
                XCTAssertEqual(try allocator.next(in: other), 1)
            }
            XCTAssertEqual(try allocator.next(in: seeded), UInt64.max)
            XCTAssertFalse(allocator.isExhausted)
            XCTAssertThrowsError(try allocator.next(in: seeded))
            for other in PlaybackIdentityNamespace.allCases {
                XCTAssertThrowsError(try allocator.next(in: other))
            }
        }
    }

    func testActivationInvocationHasCheckedDedicatedDomainAndNonreusableIssuer() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1)
        XCTAssertEqual(try allocator.next(in: .nonce), UInt64.max)
        let invocation = try AudioSessionActivationInvocationIdentity(allocator: allocator)
        XCTAssertTrue(invocation.wasIssued(by: allocator))
        let other = PlaybackIdentityAllocator(initialIssuedValue: .max - 1)
        let foreign = try AudioSessionActivationInvocationIdentity(allocator: other)
        XCTAssertNotEqual(invocation, foreign)
        XCTAssertFalse(invocation.wasIssued(by: other))
        XCTAssertFalse(invocation.isLater(than: foreign))
        XCTAssertThrowsError(try AudioSessionActivationInvocationIdentity(allocator: allocator))
        for domain in PlaybackIdentityNamespace.allCases { XCTAssertThrowsError(try allocator.next(in: domain)) }
    }

    func testControlIdentityDomainsExhaustIndependentlyAndThenRejectGlobally() throws {
        // 新控制身份的完整域映射；同一实例耗尽后不能绕到另一域继续签发。
        let domains: [PlaybackIdentityNamespace] = [
            .safetyIngress, .systemEvent, .mediaServices, .interruption,
            .resetRoot, .freezeGeneration, .intent, .audioSessionActivationInvocation, .audioSessionConfigurationGeneration
        ]
        for domain in domains {
            let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1)
            XCTAssertEqual(try allocator.next(in: domain), UInt64.max)
            XCTAssertThrowsError(try allocator.next(in: domain))
            for other in PlaybackIdentityNamespace.allCases {
                XCTAssertThrowsError(try allocator.next(in: other))
            }
        }
    }

    func testExhaustionRejectsEveryNamespaceWithoutReusingAnIdentity() throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1)

        XCTAssertEqual(try allocator.next(in: .session), UInt64.max)
        XCTAssertThrowsError(try allocator.next(in: .session)) {
            XCTAssertEqual($0 as? PlaybackIdentityAllocationError, .identitySpaceExhausted)
        }
        XCTAssertTrue(allocator.isExhausted)
        XCTAssertThrowsError(try allocator.next(in: .backend))
        XCTAssertThrowsError(try allocator.next(in: .session))
    }

    func testAllocationsStartAtOneAndNamespacesAreIndependent() throws {
        let allocator = PlaybackIdentityAllocator()

        XCTAssertEqual(try allocator.next(in: .session), 1)
        XCTAssertEqual(try allocator.next(in: .session), 2)
        XCTAssertEqual(try allocator.next(in: .backend), 1)
        XCTAssertEqual(try allocator.next(in: .backend), 2)
        XCTAssertFalse(allocator.isExhausted)
    }

    func testConcurrentCallersReceiveEveryIdentityExactlyOnce() async throws {
        let allocator = PlaybackIdentityAllocator()
        let issued = IssuedIdentities()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<125 {
                        let identity = try! allocator.next(in: .mediaEpoch)
                        issued.append(identity)
                    }
                }
            }
        }

        let result = issued.snapshot()
        XCTAssertEqual(result.count, 1_000)
        XCTAssertEqual(Set(result), Set(1...1_000))
    }
}

private final class IssuedIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [UInt64]()

    func append(_ value: UInt64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
