// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import UIKit
import XCTest
@testable import VPlayerCore
@testable import VPlayerPlayback

@MainActor
final class IOSPlatformBoundaryTests: XCTestCase {
    func testPhoneDisplayAdapterNeverSynthesizesTVSwitchEvents() throws {
        let recorder = DisplayModeRecorder()
        let context = PlaybackPresentationContext(displayModeFactory: { _, _, _ in
            recorder.created += 1
            return recorder
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "Hosted iOS boundary test requires the app window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let view = context.makeVideoView()
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264, width: 1920, height: 1080,
            extensions: nil, formatDescriptionOut: &format), noErr)
        let description = try XCTUnwrap(format)
        context.attach(to: window)
        context.attach(to: window)
        context.updateDisplayCriteria(formatDescription: description, outputFrameRate: 50)
        context.updateDisplayCriteria(formatDescription: description, outputFrameRate: 50)
        XCTAssertEqual(recorder.created, 1)
        XCTAssertEqual(recorder.rates, [50])
        context.teardown()
        context.updateDisplayCriteria(formatDescription: description, outputFrameRate: 60)
        context.attach(to: window)
        XCTAssertEqual(recorder.rates, [50])
        XCTAssertEqual(recorder.created, 1)
        XCTAssertTrue(view === context.makeVideoView())
        XCTAssertNil(view.windowDidChange)
    }

    func testBluetoothA2DPHFPAndLEStayOnLocalSampleBufferPathAcrossVisualActivity() async throws {
        let sdk = AudioSessionSDKSpy(categoryResults: [], multichannelFails: false,
            executor: ControlTaskRegistry().executor)
        let salt = try XCTUnwrap(AudioSessionEndpointSalt.make(using: sdk))
        for port in [AVAudioSession.Port.bluetoothA2DP, .bluetoothHFP, .bluetoothLE] {
            let route = GraphRouteSnapshot([.init(uid: "synthetic-headset",
                portType: port.rawValue as NSString, dataSource: .missing)])
            guard case let .available(ports, _, _) = AudioSessionBlockingCallLane.project(route, salt: salt) else {
                return XCTFail("Bluetooth endpoint projection failed")
            }
            XCTAssertEqual(ports, .bluetooth)
            XCTAssertFalse(ports.contains(.airPlay))
            let harness = RouteServiceTestHarness(initialPorts: ports)
            try await harness.acquireWithoutNotification()
            await harness.advanceThroughStabilityWindow()
            let visualGate = GPUVideoProcessingGate()
            for foreground in [true, false, true] {
                visualGate.setForeground(foreground)
                XCTAssertEqual(harness.committedBackend, .sampleBuffer)
            }
        }
    }

    func testPhoneStoreUsesApplicationSupportAndDeploymentLabel() throws {
        let url = try VPlayerModelContainer.persistentStoreRootURL()
        let expected = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        XCTAssertEqual(url, expected)
        XCTAssertEqual(VPlayerCore.deploymentTarget, "iOS 27.0")
    }
}

@MainActor
private final class DisplayModeRecorder: PlaybackDisplayModeControlling {
    var created = 0
    var rates: [Float] = []
    func enterFullScreen(formatDescription: CMFormatDescription, outputFrameRate: Float) {
        rates.append(outputFrameRate)
    }
    func leaveFullScreen() {}
}
