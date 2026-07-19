// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class PlaybackSerialExecutorTests: XCTestCase {
    func testExecutesOneThousandOperationsInSubmissionOrder() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.executor.order")
        let probe = ExecutorProbe()
        let result = LockedSnapshotBox<ExecutorProbe.Snapshot>()
        let finished = expectation(description: "all submitted operations complete")

        for expected in 1...1_000 {
            executor.submit {
                probe.record(expected: expected, isIsolated: executor.isIsolated)
                if expected == 1_000 {
                    result.store(probe.snapshot)
                    finished.fulfill()
                }
            }
        }

        wait(for: [finished], timeout: 5)
        let snapshot = try XCTUnwrap(result.load())
        XCTAssertEqual(snapshot.count, 1_000)
        XCTAssertTrue(snapshot.wasOrdered)
        XCTAssertTrue(snapshot.wasAlwaysIsolated)
    }

    func testEqualLabelsStillHaveDistinctIsolationDomains() throws {
        let executorA = PlaybackSerialExecutor(label: "org.vplayer.tests.executor.equal")
        let executorB = PlaybackSerialExecutor(label: "org.vplayer.tests.executor.equal")
        let result = LockedSnapshotBox<[Bool]>()
        let finished = expectation(description: "both executor domains observed")

        XCTAssertFalse(executorA.isIsolated)
        XCTAssertFalse(executorB.isIsolated)

        executorA.submit {
            let onA = [executorA.isIsolated, executorB.isIsolated]
            executorB.submit {
                result.store(onA + [executorA.isIsolated, executorB.isIsolated])
                finished.fulfill()
            }
        }

        wait(for: [finished], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(result.load()), [true, false, false, true])
    }

    func testNestedSubmissionRemainsAsynchronousAndNonReentrant() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.executor.reentrant")
        let probe = ExecutorProbe()
        let result = LockedSnapshotBox<ExecutorProbe.Snapshot>()
        let finished = expectation(description: "nested operation completes")

        executor.submit {
            probe.append(1)
            executor.submit {
                probe.append(3)
                result.store(probe.snapshot)
                finished.fulfill()
            }
            probe.append(2)
        }

        wait(for: [finished], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(result.load()).values, [1, 2, 3])
    }
}

private final class ExecutorProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        let count: Int
        let wasOrdered: Bool
        let wasAlwaysIsolated: Bool
        let values: [Int]
    }

    private var count = 0
    private var wasOrdered = true
    private var wasAlwaysIsolated = true
    private var values: [Int] = []

    func record(expected: Int, isIsolated: Bool) {
        count += 1
        wasOrdered = wasOrdered && count == expected
        wasAlwaysIsolated = wasAlwaysIsolated && isIsolated
    }

    func append(_ value: Int) {
        values.append(value)
    }

    var snapshot: Snapshot {
        Snapshot(
            count: count,
            wasOrdered: wasOrdered,
            wasAlwaysIsolated: wasAlwaysIsolated,
            values: values
        )
    }
}

private final class LockedSnapshotBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
