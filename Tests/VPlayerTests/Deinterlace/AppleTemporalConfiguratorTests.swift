// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
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

    func testTheOnlyRequiredPropertyIsPreflightedBeforeAnyPropertyMutation() {
        for keys: Set<String> in [[deinterlaceModeKey], []] {
            let api = FakeVideoToolboxAPI()
            let session = FakeVideoToolboxSession(id: VTSessionID(rawValue: 1))
            api.enqueueSupportedPropertySnapshot(.init(
                status: noErr,
                supportedPropertyKeys: keys
            ))

            assertFailure(.unsupportedProperty(fieldModeKey)) {
                try AppleTemporalConfigurator(api: api).configure(session: session)
            }

            XCTAssertEqual(api.snapshot.operations, ["supported"])
            XCTAssertTrue(api.snapshot.sets.isEmpty)
        }
    }

    // Every decoder Apple currently ships omits DeinterlaceMode, including the
    // ones that implement FieldMode. Requiring it made the Apple route report
    // itself unavailable on every platform rather than deinterlacing with the
    // decoder's own algorithm.
    func testAnUnlistedDeinterlaceModeStillDeinterlacesWithFieldModeAlone() throws {
        let api = FakeVideoToolboxAPI()
        let session = FakeVideoToolboxSession(id: VTSessionID(rawValue: 7))
        api.enqueueSupportedPropertySnapshot(.init(
            status: noErr,
            supportedPropertyKeys: [fieldModeKey]
        ))

        try AppleTemporalConfigurator(api: api).configure(session: session)

        XCTAssertEqual(api.snapshot.operations, ["supported", "set"])
        XCTAssertEqual(api.snapshot.sets, [
            .init(
                sessionID: VTSessionID(rawValue: 7),
                key: fieldModeKey,
                value: .string(kVTDecompressionProperty_FieldMode_DeinterlaceFields as String)
            ),
        ])
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

    // Runs against the real VideoToolbox, on whatever this suite executes on.
    //
    // It deliberately does not assert that Apple implements the deinterlace
    // properties — as of tvOS 26.2 no decoder there does, on device or in the
    // simulator, which is why the Apple route always reports itself
    // unavailable. What it pins down is that the pipeline's answer comes from
    // the decoder rather than from an assumption: the day a decoder lists
    // FieldMode, the route has to configure instead of falling back, and the
    // day one stops, it has to fall back instead of failing to decode.
    func testRealDecoderCapabilityDecidesWhetherTheAppleRouteConfigures() throws {
        let format = try interlacedH264FormatDescription()
        let api = SystemVideoToolboxAPI()
        let creation = api.createSession(
            format: format,
            decoderSpecification: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String:
                    .boolean(true),
            ],
            imageBufferAttributes: [
                kCVPixelBufferMetalCompatibilityKey as String: .boolean(true),
                kCVPixelBufferIOSurfacePropertiesKey as String: .dictionary([:]),
            ]
        )
        let session = try XCTUnwrap(creation.session, "session create \(creation.status)")
        defer { api.invalidate(session) }
        let snapshot = api.copySupportedPropertySnapshot(session)
        XCTAssertEqual(snapshot.status, noErr)
        let supportedKeys = try XCTUnwrap(snapshot.supportedPropertyKeys)
        let deinterlaces = AppleTemporalConfigurator.supportsDeinterlaceFields(supportedKeys)

        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.temporal.capability")
        let decoder = VideoToolboxDecoder(executor: executor) { _ in }
        defer { decoder.invalidate() }
        let generation = MediaGeneration(rawValue: 1)
        try decoder.configure(
            format: format,
            generation: generation,
            configuration: .bothFields
        )

        XCTAssertEqual(decoder.supportsConfiguration(.bothFields), true)
        XCTAssertEqual(
            decoder.supportsConfiguration(.appleTemporal),
            deinterlaces,
            "the route decision must follow the decoder's own property list"
        )

        do {
            try decoder.configure(
                format: format,
                generation: generation,
                configuration: .appleTemporal
            )
            XCTAssertTrue(deinterlaces, "a decoder without FieldMode must not configure")
        } catch let failure as VideoDecoderFailure {
            XCTAssertFalse(deinterlaces, "a decoder with FieldMode must configure: \(failure)")
            XCTAssertEqual(
                failure,
                .temporalUnavailable(.unsupportedProperty(fieldModeKey))
            )
        }
    }

    /// 1080i H.264 High@4.1 parameter sets lifted from
    /// `Tests/VPlayerTests/Fixtures/Media/interlaced-h264-mp2.ts`, so the
    /// decoder is asked about exactly the content the Apple route exists for.
    private func interlacedH264FormatDescription() throws -> CMVideoFormatDescription {
        let sps: [UInt8] = [
            0x67, 0x64, 0x00, 0x29, 0xAC, 0xD9, 0x40, 0x78, 0x04, 0x4F,
            0xDE, 0x02, 0xD4, 0x04, 0x04, 0x05, 0x00, 0x00, 0x03, 0x00,
            0x01, 0x00, 0x00, 0x03, 0x00, 0x32, 0x9F, 0x16, 0x2D, 0x96,
        ]
        let pps: [UInt8] = [0x68, 0xFE, 0x8F, 0xCB]
        let format = try VideoFormatDescriptionBuilder.make(
            codec: .h264,
            parameterSets: [Data(sps), Data(pps)]
        )
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(dimensions.width, 1_920)
        XCTAssertEqual(dimensions.height, 1_080)
        return format
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
