// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class SystemAudioSessionConfiguratorTests: XCTestCase {
    func testFirstAcquisitionConfiguresLongFormMultichannelThenActivates() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events, [
            .category(.longFormAudio),
            .multichannel,
            .activate,
        ])
        try await harness.release(handoff)
    }

    func testLongFormFailureFallsBackToDefaultBeforeActivation() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.failure, .success])
        let handoff = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events, [
            .category(.longFormAudio),
            .category(.default),
            .multichannel,
            .activate,
        ])
        try await harness.release(handoff)
    }

    func testSequentialAcquisitionsReuseProcessAndMultichannelState() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let first = try await harness.acquire()
        try await harness.release(first)
        let second = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 2)
        try await harness.release(second)
    }

    func testMultichannelFailureDoesNotPreventActivation() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], multichannelFails: true)
        let handoff = try await harness.acquire()
        XCTAssertEqual(harness.sdk.events, [
            .category(.longFormAudio),
            .multichannel,
            .activate,
        ])
        try await harness.release(handoff)
    }

    func testAcquisitionActivationFailureDoesNotProduceReadyReceipt() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success], activationFailures: 1)
        let ticket = try harness.prepareAcquisition()
        XCTAssertTrue(harness.owner.startAcquisition(ticket, receiver: harness.receiver))
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(harness.registry.outputAcquisitionCommitSnapshot())
    }

    func testFailureDiagnosticsPreserveFixedDomainAndClampedCode() async throws {
        let harness = try AudioSessionLifecycleTestHarness(
            categoryResults: [.failure, .success],
            categoryFailure: NSError(domain: NSOSStatusErrorDomain, code: 42)
        )
        let handoff = try await harness.acquire()
        let reason = harness.registry.processAudioSessionReceiptSnapshot()?.preferredFailureReason
        XCTAssertEqual(reason, .init(domain: .osStatus, code: 42))
        try await harness.release(handoff)
    }

    func testMediaServicesResetInvalidatesProcess() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success, .success])
        let first = try await harness.acquire()
        try await harness.release(first)
        harness.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        XCTAssertNil(harness.registry.processAudioSessionReceiptSnapshot())
        let second = try await harness.acquire(reset: true)
        let context = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(harness.registry.beginOutputResetConfigurationActivation(contextNonce: context.contextNonce))
        XCTAssertEqual(harness.owner.invoke(activation, receiver: harness.receiver), .started)
        for _ in 0..<500 {
            if harness.sdk.events.filter({ $0 == .activate }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(harness.sdk.events.filter { $0 == .activate }.count, 2)
        try await harness.release(second)
    }

    func testInterruptionBeganIncrementsSafetyIngressRevision() async throws {
        let harness = try AudioSessionLifecycleTestHarness(categoryResults: [.success])
        let handoff = try await harness.acquire()
        let before = harness.registry.executor.safetyIngress.snapshot.throughRevision
        harness.registry.executor.safetyIngress.performSyncIngress(.interruptionBegan)
        XCTAssertGreaterThan(harness.registry.executor.safetyIngress.snapshot.throughRevision, before)
        try await harness.release(handoff)
    }
}
