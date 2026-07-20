// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class AppleTemporalConfiguratorTests: XCTestCase {
    private let fieldModeKey = kVTDecompressionPropertyKey_FieldMode as String
    private let deinterlaceModeKey = kVTDecompressionPropertyKey_DeinterlaceMode as String

    func testFailureAndSupportedPropertySnapshotContractsAreEquatableAndSendable() {
        requireSendable(AppleTemporalFailure.self)
        requireSendable(VideoDecoderFailure.self)
        requireSendable(VTSupportedPropertySnapshot.self)

        XCTAssertEqual(
            AppleTemporalFailure.unsupportedProperty("key"),
            .unsupportedProperty("key")
        )
        XCTAssertEqual(
            AppleTemporalFailure.propertySetFailed(key: "key", status: -1),
            .propertySetFailed(key: "key", status: -1)
        )
        XCTAssertEqual(
            AppleTemporalFailure.initializationFailed(status: -2),
            .initializationFailed(status: -2)
        )
        XCTAssertEqual(
            AppleTemporalFailure.processingFailed(status: -3),
            .processingFailed(status: -3)
        )
        XCTAssertEqual(
            VideoDecoderFailure.temporalUnavailable(.processingFailed(status: -3)),
            .temporalUnavailable(.processingFailed(status: -3))
        )
    }

    func testQueriesExactlyOnceThenSetsExactValuesInRequiredOrder() throws {
        let api = FakeVideoToolboxAPI()
        let session = FakeVideoToolboxSession(id: VTSessionID(rawValue: 41))

        try AppleTemporalConfigurator(api: api).configure(session: session)

        let snapshot = api.snapshot
        XCTAssertEqual(snapshot.operations, ["supported", "set", "set"])
        XCTAssertEqual(snapshot.supportedPropertyQueries, [VTSessionID(rawValue: 41)])
        XCTAssertEqual(snapshot.sets, [
            .init(
                sessionID: VTSessionID(rawValue: 41),
                key: fieldModeKey,
                value: .string(kVTDecompressionProperty_FieldMode_DeinterlaceFields as String)
            ),
            .init(
                sessionID: VTSessionID(rawValue: 41),
                key: deinterlaceModeKey,
                value: .string(kVTDecompressionProperty_DeinterlaceMode_Temporal as String)
            ),
        ])
    }

    func testQueryErrorAndImpossibleSuccessfulNilSnapshotSetNothing() {
        let status: OSStatus = -12_301
        let cases: [(VTSupportedPropertySnapshot, AppleTemporalFailure)] = [
            (
                .init(status: status, supportedPropertyKeys: [fieldModeKey, deinterlaceModeKey]),
                .initializationFailed(status: status)
            ),
            (
                .init(status: noErr, supportedPropertyKeys: nil),
                .initializationFailed(status: kVTParameterErr)
            ),
        ]

        for (queryResult, expected) in cases {
            let api = FakeVideoToolboxAPI()
            let session = FakeVideoToolboxSession(id: VTSessionID(rawValue: 1))
            api.enqueueSupportedPropertySnapshot(queryResult)

            assertFailure(expected) {
                try AppleTemporalConfigurator(api: api).configure(session: session)
            }

            XCTAssertEqual(api.snapshot.operations, ["supported"])
            XCTAssertEqual(api.snapshot.supportedPropertyQueries.count, 1)
            XCTAssertTrue(api.snapshot.sets.isEmpty)
        }
    }

    func testEveryMissingKeyIsPreflightedBeforeAnyPropertyMutation() {
        let cases: [(Set<String>, String)] = [
            ([deinterlaceModeKey], fieldModeKey),
            ([fieldModeKey], deinterlaceModeKey),
            ([], fieldModeKey),
        ]

        for (keys, expectedMissingKey) in cases {
            let api = FakeVideoToolboxAPI()
            let session = FakeVideoToolboxSession(id: VTSessionID(rawValue: 1))
            api.enqueueSupportedPropertySnapshot(.init(
                status: noErr,
                supportedPropertyKeys: keys
            ))

            assertFailure(.unsupportedProperty(expectedMissingKey)) {
                try AppleTemporalConfigurator(api: api).configure(session: session)
            }

            XCTAssertEqual(api.snapshot.operations, ["supported"])
            XCTAssertTrue(api.snapshot.sets.isEmpty)
        }
    }

    func testFirstSetFailureStopsBeforeSecondSet() {
        let api = FakeVideoToolboxAPI()
        let session = FakeVideoToolboxSession(id: VTSessionID(rawValue: 1))
        let status: OSStatus = -12_302
        api.enqueueSetStatus(status)

        assertFailure(.propertySetFailed(key: fieldModeKey, status: status)) {
            try AppleTemporalConfigurator(api: api).configure(session: session)
        }

        XCTAssertEqual(api.snapshot.operations, ["supported", "set"])
        XCTAssertEqual(api.snapshot.sets.map(\.key), [fieldModeKey])
    }

    func testSecondSetFailureKeepsRequiredOrderAndExactFailureKey() {
        let api = FakeVideoToolboxAPI()
        let session = FakeVideoToolboxSession(id: VTSessionID(rawValue: 1))
        let status: OSStatus = -12_303
        api.enqueueSetStatus(noErr)
        api.enqueueSetStatus(status)

        assertFailure(.propertySetFailed(key: deinterlaceModeKey, status: status)) {
            try AppleTemporalConfigurator(api: api).configure(session: session)
        }

        XCTAssertEqual(api.snapshot.operations, ["supported", "set", "set"])
        XCTAssertEqual(api.snapshot.sets.map(\.key), [fieldModeKey, deinterlaceModeKey])
    }

    private func assertFailure(
        _ expected: AppleTemporalFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let failure as AppleTemporalFailure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

private func requireSendable<T: Sendable>(_: T.Type) {}
