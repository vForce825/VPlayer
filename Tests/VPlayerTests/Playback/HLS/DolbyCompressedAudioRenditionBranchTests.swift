// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class DolbyCompressedAudioRenditionBranchTests: XCTestCase {
    func testForeignProducerAuthorizationCannotCreateBranchOrWriter() throws {
        let first = try DolbyProducerTestHarness()
        let second = try DolbyProducerTestHarness()
        _ = try first.proof(id: 1, sample: 0)
        let authorization = try first.authorization()
        XCTAssertThrowsError(try DolbyCompressedAudioRenditionBranch(producer: second.producer,
            authorization: authorization, boundary: SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero)),
            initialFormatAdmission: { _, _, _ in true }, writerFactory: { _, _, _ in
                XCTFail("Foreign authorization must not reach writer creation")
                throw DolbyAudioSourceFailure.invalidSourceProof
            }))
    }

    func testNoInputFinishCannotInventEOFOrCreateWriter() async throws {
        let harness = try DolbyProducerTestHarness()
        _ = try harness.proof(id: 1, sample: 0)
        let branch = try DolbyCompressedAudioRenditionBranch(producer: harness.producer,
            authorization: harness.authorization(), boundary: SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero)),
            initialFormatAdmission: { _, _, _ in true }, writerFactory: { _, _, _ in
                XCTFail("No output AU exists")
                throw DolbyAudioSourceFailure.invalidSourceProof
            })
        do { _ = try await branch.finish(); XCTFail("Expected missing source drain") }
        catch { XCTAssertEqual(error as? DolbyCompressedAudioRenditionFailure, .noWriter) }
        XCTAssertNil(branch.writer)
    }

    func testCancellationBeforeFirstWriterCannotBecomeSourceDrain() async throws {
        let harness = try DolbyProducerTestHarness()
        _ = try harness.proof(id: 1, sample: 0)
        let branch = try DolbyCompressedAudioRenditionBranch(producer: harness.producer,
            authorization: harness.authorization(), boundary: SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero)),
            initialFormatAdmission: { _, _, _ in true }, writerFactory: { _, _, _ in
                XCTFail("Cancelled branch must not create a writer")
                throw DolbyAudioSourceFailure.invalidSourceProof
            })
        await branch.cancelAndAwait()
        XCTAssertThrowsError(try harness.producer.finishSourceInput())
        XCTAssertThrowsError(try harness.producer.requireSourceDrained(throughFrameID: 1))
        XCTAssertEqual(branch.physicalWriterCount, 0)
    }
}
