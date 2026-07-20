// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import XCTest
@testable import VPlayerPlayback

@MainActor
final class DisplayCriteriaControllerTests: XCTestCase {
    func testExactFiftyAndNonFiftyRatesUseIdenticalFormatDescriptionObject() throws {
        for rate: Float in [50, 23.976, 59.94] {
            let manager = FakeDisplayCriteriaManager()
            let link = FakeDisplayLinkControl()
            let readiness = FakeDisplayReadinessControl()
            var captured: [(Float, CMFormatDescription)] = []
            let subject = DisplayCriteriaController(
                manager: manager,
                notificationCenter: NotificationCenter(),
                criteriaFactory: { refreshRate, format in
                    captured.append((refreshRate, format))
                    return AVDisplayCriteria(refreshRate: refreshRate, formatDescription: format)
                },
                displayLink: link,
                readiness: readiness
            )
            let format = try makeFormatDescription()

            subject.enterFullScreen(formatDescription: format, outputFrameRate: rate)

            XCTAssertEqual(captured.count, 1)
            XCTAssertEqual(try XCTUnwrap(captured.first?.0), rate, accuracy: 0.0001)
            XCTAssertTrue(captured.first?.1 === format)
            XCTAssertNotNil(manager.preferredDisplayCriteria)
        }
    }

    func testObserversAreInstalledBeforeCriteriaMutation() throws {
        let center = NotificationCenter()
        let manager = FakeDisplayCriteriaManager()
        var sharedOrder: [String] = []
        let link = FakeDisplayLinkControl(order: { sharedOrder.append($0) })
        let readiness = FakeDisplayReadinessControl(order: { sharedOrder.append($0) })
        manager.beforeMutation = {
            center.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
        }
        let subject = makeSubject(
            manager: manager,
            center: center,
            link: link,
            readiness: readiness
        )

        subject.enterFullScreen(
            formatDescription: try makeFormatDescription(),
            outputFrameRate: 50
        )

        XCTAssertEqual(link.operations, ["pause"])
        XCTAssertEqual(readiness.operations, ["close"])
        XCTAssertEqual(sharedOrder, ["pause", "close"])
    }

    func testModeSwitchStartIsIdempotentAndEndAnchorsBeforeResume() throws {
        let center = NotificationCenter()
        let manager = FakeDisplayCriteriaManager()
        var sharedOrder: [String] = []
        let link = FakeDisplayLinkControl(order: { sharedOrder.append($0) })
        let readiness = FakeDisplayReadinessControl(order: { sharedOrder.append($0) })
        let subject = makeSubject(manager: manager, center: center, link: link, readiness: readiness)
        subject.enterFullScreen(
            formatDescription: try makeFormatDescription(),
            outputFrameRate: 50
        )

        center.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
        center.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
        center.post(name: .AVDisplayManagerModeSwitchEnd, object: nil)
        center.post(name: .AVDisplayManagerModeSwitchEnd, object: nil)

        XCTAssertEqual(link.operations.filter { $0 == "pause" }.count, 1)
        XCTAssertEqual(readiness.operations.filter { $0 == "close" }.count, 1)
        XCTAssertEqual(readiness.operations.filter { $0 == "anchor" }.count, 1)
        XCTAssertEqual(link.operations.filter { $0 == "resume" }.count, 1)
        XCTAssertEqual(link.operations.filter { $0 == "reset" }.count, 1)
        XCTAssertEqual(sharedOrder.prefix(2), ["pause", "close"])
        XCTAssertEqual(sharedOrder.suffix(3), ["anchor", "reset", "resume"])
    }

    func testModeSwitchEndDoesNotResetOrResumeWhenPipelineReadinessIsStillClosed() throws {
        let center = NotificationCenter()
        let manager = FakeDisplayCriteriaManager()
        let link = FakeDisplayLinkControl()
        let readiness = FakeDisplayReadinessControl()
        readiness.allowsReanchor = false
        let subject = makeSubject(manager: manager, center: center, link: link, readiness: readiness)
        subject.enterFullScreen(
            formatDescription: try makeFormatDescription(),
            outputFrameRate: 50
        )

        center.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
        center.post(name: .AVDisplayManagerModeSwitchEnd, object: nil)

        XCTAssertEqual(readiness.operations, ["close", "anchor"])
        XCTAssertEqual(link.operations, ["pause"])
    }

    func testLeaveDuringModeSwitchCancelsReadinessWithoutResetOrResume() throws {
        let center = NotificationCenter()
        let manager = FakeDisplayCriteriaManager()
        var sharedOrder: [String] = []
        let link = FakeDisplayLinkControl(order: { sharedOrder.append($0) })
        let readiness = FakeDisplayReadinessControl(order: { sharedOrder.append($0) })
        let subject = makeSubject(
            manager: manager,
            center: center,
            link: link,
            readiness: readiness
        )
        subject.enterFullScreen(
            formatDescription: try makeFormatDescription(),
            outputFrameRate: 50
        )
        center.post(name: .AVDisplayManagerModeSwitchStart, object: nil)

        subject.leaveFullScreen()
        center.post(name: .AVDisplayManagerModeSwitchEnd, object: nil)

        XCTAssertEqual(readiness.operations, ["close", "anchor"])
        XCTAssertEqual(link.operations, ["pause", "pause"])
        XCTAssertEqual(sharedOrder, ["pause", "close", "pause", "anchor"])
        XCTAssertNil(manager.preferredDisplayCriteria)
    }

    func testLeaveRemovesObserversPausesAndUnconditionallyClearsCriteria() throws {
        let center = NotificationCenter()
        let manager = FakeDisplayCriteriaManager()
        let link = FakeDisplayLinkControl()
        let readiness = FakeDisplayReadinessControl()
        let subject = makeSubject(manager: manager, center: center, link: link, readiness: readiness)
        let format = try makeFormatDescription()

        subject.enterFullScreen(formatDescription: format, outputFrameRate: 50)
        subject.leaveFullScreen()
        subject.leaveFullScreen()
        XCTAssertNil(manager.preferredDisplayCriteria)
        let operationCount = link.operations.count + readiness.operations.count

        center.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
        center.post(name: .AVDisplayManagerModeSwitchEnd, object: nil)
        XCTAssertEqual(link.operations.count + readiness.operations.count, operationCount)
        XCTAssertGreaterThanOrEqual(link.operations.filter { $0 == "pause" }.count, 1)
        XCTAssertEqual(manager.nilAssignmentCount, 2)
    }

    func testRepeatedEnterLeaveAndStaleNotificationsAreHarmless() throws {
        let center = NotificationCenter()
        let manager = FakeDisplayCriteriaManager()
        let link = FakeDisplayLinkControl()
        let readiness = FakeDisplayReadinessControl()
        let subject = makeSubject(manager: manager, center: center, link: link, readiness: readiness)
        let format = try makeFormatDescription()

        for _ in 0..<3 {
            subject.enterFullScreen(formatDescription: format, outputFrameRate: 50)
            subject.enterFullScreen(formatDescription: format, outputFrameRate: 50)
            center.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
            center.post(name: .AVDisplayManagerModeSwitchEnd, object: nil)
            subject.leaveFullScreen()
            center.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
            center.post(name: .AVDisplayManagerModeSwitchEnd, object: nil)
        }

        XCTAssertNil(manager.preferredDisplayCriteria)
        XCTAssertEqual(readiness.operations.filter { $0 == "anchor" }.count, 3)
        XCTAssertEqual(link.operations.filter { $0 == "reset" }.count, 3)
        XCTAssertEqual(link.operations.filter { $0 == "resume" }.count, 3)
    }

    private func makeSubject(
        manager: FakeDisplayCriteriaManager,
        center: NotificationCenter,
        link: FakeDisplayLinkControl,
        readiness: FakeDisplayReadinessControl
    ) -> DisplayCriteriaController {
        DisplayCriteriaController(
            manager: manager,
            notificationCenter: center,
            criteriaFactory: { AVDisplayCriteria(refreshRate: $0, formatDescription: $1) },
            displayLink: link,
            readiness: readiness
        )
    }

    private func makeFormatDescription() throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: kCMVideoCodecType_HEVC,
            width: 1_920,
            height: 1_080,
            extensions: nil,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }
}

@MainActor
private final class FakeDisplayCriteriaManager: DisplayCriteriaManaging {
    var beforeMutation: (() -> Void)?
    var nilAssignmentCount = 0
    var preferredDisplayCriteria: AVDisplayCriteria? {
        didSet {
            beforeMutation?()
            if preferredDisplayCriteria == nil {
                nilAssignmentCount += 1
            }
        }
    }
}

@MainActor
private final class FakeDisplayLinkControl: DisplayLinkControlling {
    let order: ((String) -> Void)?
    var operations: [String] = []

    init(order: ((String) -> Void)? = nil) {
        self.order = order
    }

    func pause() {
        operations.append("pause")
        order?("pause")
    }

    func resume() {
        operations.append("resume")
        order?("resume")
    }

    func resetPresentationTiming() {
        operations.append("reset")
        order?("reset")
    }
}

@MainActor
private final class FakeDisplayReadinessControl: DisplayReadinessControlling {
    let order: ((String) -> Void)?
    var operations: [String] = []
    var allowsReanchor = true

    init(order: ((String) -> Void)? = nil) {
        self.order = order
    }

    func closeForDisplayModeSwitch() {
        operations.append("close")
        order?("close")
    }

    func reanchorAfterDisplayModeSwitch() -> Bool {
        operations.append("anchor")
        order?("anchor")
        return allowsReanchor
    }
}
