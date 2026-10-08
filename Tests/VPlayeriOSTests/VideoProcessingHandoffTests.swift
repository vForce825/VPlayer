// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class VideoProcessingHandoffTests: XCTestCase {
    func testBackgroundClosesGPUAdmissionAndFenceJoinsActualCompletion() throws {
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        var ticket: GPUVideoWorkTicket?
        XCTAssertNil(try gate.withGPUAdmission { ticket = $0 })
        gate.setForeground(false)
        let fence = try XCTUnwrap(try gate.withGPUAdmission { _ in XCTFail("GPU after background") })
        XCTAssertFalse(fence.wait(timeout: .now()))
        try XCTUnwrap(ticket).finish()
        XCTAssertTrue(fence.wait(timeout: .now()))
        ticket?.finish() // Completion is idempotent, never an over-release.
        XCTAssertTrue(fence.wait(timeout: .now()))
    }
    func testForegroundReturnsToGPUOnlyAfterPiPStops() throws {
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        gate.setPictureInPicture(true)
        XCTAssertNotNil(try gate.withGPUAdmission { _ in XCTFail("PiP must use CPU") })
        gate.setForeground(false)
        gate.setForeground(true)
        XCTAssertNotNil(try gate.withGPUAdmission { _ in XCTFail("Still in PiP") })
        gate.setPictureInPicture(false)
        XCTAssertNil(try gate.withGPUAdmission { $0.finish() })
    }
    func testRapidTransitionsDoNotStickInCPUOrBorrowLaterGPUFence() throws {
        let gate = GPUVideoProcessingGate()
        for _ in 0..<20 {
            gate.setForeground(true)
            var old: GPUVideoWorkTicket?
            XCTAssertNil(try gate.withGPUAdmission { old = $0 })
            gate.setForeground(false)
            let fence = try XCTUnwrap(try gate.withGPUAdmission { _ in XCTFail() })
            gate.setForeground(true)
            var current: GPUVideoWorkTicket?
            XCTAssertNil(try gate.withGPUAdmission { current = $0 })
            old?.finish()
            XCTAssertTrue(fence.wait(timeout: .now()), "A retired fence cannot wait for later foreground work")
            current?.finish()
        }
    }
}
