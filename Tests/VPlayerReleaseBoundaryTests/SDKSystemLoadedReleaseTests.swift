// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import VPlayerPlayback

private final class ReleaseWeakFoundationURLOwnerBox {
    weak var value: NSURL?
}

private struct ReleaseScopedRuntimeObservation {
    let urlOwner: ReleaseWeakFoundationURLOwnerBox
    let sawInstalledOwner: Bool
    let preparedItemMatched: Bool
}

@MainActor
final class SDKSystemLoadedReleaseTests: XCTestCase {
    /// 纯观测入口：若真实System prepare任一阶段不再可达或清理失败，本方法失败；
    /// allocation数值由同次LLDB在原调用点读取，不把测试探针分配当生产分配。
    func testReleaseRuntimePrepareAndScopedURLLifetimeObservation() async throws {
        print("TASK21_RELEASE_RUNTIME stage=attach-window pid=\(getpid())")
        _ = releaseWaitUntil(timeout: 15) { false }

        let observation = try await makeScopedRuntimeObservation()
        XCTAssertTrue(observation.sawInstalledOwner)
        XCTAssertTrue(observation.preparedItemMatched)

        let aliveImmediatelyAfterApplicationScope = observation.urlOwner.value != nil
        autoreleasepool {}
        let aliveAfterCallerAutoreleasepool = observation.urlOwner.value != nil
        let releasedWhileRunLoopCouldRun = releaseWaitUntil(timeout: 2) {
            observation.urlOwner.value == nil
        }
        let aliveAfterRunnableRunLoop = observation.urlOwner.value != nil
        let yieldDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while observation.urlOwner.value != nil, ContinuousClock.now < yieldDeadline {
            await Task.yield()
        }
        let aliveAfterTaskYields = observation.urlOwner.value != nil

        let text = [
            "sawInstalledFoundationURLOwner=\(observation.sawInstalledOwner)",
            "preparedItemMatched=\(observation.preparedItemMatched)",
            "aliveImmediatelyAfterApplicationScope=\(aliveImmediatelyAfterApplicationScope)",
            "aliveAfterCallerAutoreleasepool=\(aliveAfterCallerAutoreleasepool)",
            "releasedWhileRunLoopCouldRun=\(releasedWhileRunLoopCouldRun)",
            "aliveAfterRunnableRunLoop=\(aliveAfterRunnableRunLoop)",
            "aliveAfterTaskYields=\(aliveAfterTaskYields)",
            "说明=弱owner仅记录生命周期；未输出URL/token，未把存活归因为SDK cache，"
                + "也未给生产增加即时NSURL析构契约",
        ].joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        print("TASK21_RELEASE_RUNTIME stage=observation-complete")
    }

    @inline(never)
    private func makeScopedRuntimeObservation() async throws
        -> ReleaseScopedRuntimeObservation {
        let allocator = PlaybackIdentityAllocator()
        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: allocator)
        var fixture: ReleaseAACPublicationFixture? = try await .make(lifecycle: lifecycle)
        defer { try? fixture?.teardown() }
        let item = try XCTUnwrap(fixture).request.item
        var driver: SystemAVPlayerDriver? = try .make(player: AVPlayer())
        var coordinator: AVPlayerItemCoordinator? = try .init(
            driver: try XCTUnwrap(driver), evidenceSource: try XCTUnwrap(fixture).source,
            allocator: allocator)
        try coordinator?.install(try XCTUnwrap(fixture).request)

        let weakOwner = ReleaseWeakFoundationURLOwnerBox()
        var sawInstalledOwner = false
        autoreleasepool {
            coordinator?.inspectRetainedPreparationURLAllocations {
                role, owner, _, _, _ in
                guard role == "resource-context/installed NSURL" else { return }
                weakOwner.value = owner as? NSURL
                sawInstalledOwner = weakOwner.value != nil
            }
        }
        print("TASK21_RELEASE_RUNTIME stage=prepare-begin")
        let prepared = try await XCTUnwrap(coordinator).prepareCurrentItem()
        print("TASK21_RELEASE_RUNTIME stage=prepare-returned")

        coordinator = nil
        driver?.replaceCurrentItemWithNil(item: item)
        driver?.removeObservers(item: item)
        driver = nil
        try fixture?.teardown()
        fixture = nil
        autoreleasepool {}
        print("TASK21_RELEASE_RUNTIME stage=application-scope-ending")
        return .init(
            urlOwner: weakOwner,
            sawInstalledOwner: sawInstalledOwner,
            preparedItemMatched: prepared.item == item)
    }

    func testSystemLoopbackLoadedReceiptAndItemFailure() async throws {
        let allocator = PlaybackIdentityAllocator()
        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: allocator)
        let fixture = try await ReleaseAACPublicationFixture.make(lifecycle: lifecycle)
        defer { try? fixture.teardown() }
        let playhead = try await fixture.makePreparedPlayhead()
        let item = fixture.request.item
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer())
        try driver.install(url: fixture.request.itemURL, identity: item)
        defer { driver.replaceCurrentItemWithNil(item: item) }

        let requested = try FMP4PresentationRange(
            start: playhead.playerItemTime,
            duration: ExactMediaTime(value: 1, timescale: 100))
        let receipt = try await driver.waitForLoadedTimeRanges(
            item: item, playhead: playhead, covering: requested)
        XCTAssertEqual(receipt, .init(item: item, playhead: playhead,
                                      requested: requested))
        XCTAssertEqual(driver.activeWaiterCount, 0)

        let text = "systemDriverIdentity=\(ObjectIdentifier(driver)), "
            + "systemDriverMalloc=\(malloc_size(Unmanaged.passUnretained(driver).toOpaque())), "
            + "waitSlotIdentity=\(ObjectIdentifier(driver.prepareWait)), "
            + "waitSlotMalloc=\(malloc_size(Unmanaged.passUnretained(driver.prepareWait).toOpaque())), "
            + "receiptStride=\(MemoryLayout<AVPlayerLoadedRangeReceipt>.stride), "
            + "cResultStride=\(MemoryLayout<VPLoadedRangeCoverage>.stride)"
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)

        driver.replaceCurrentItemWithNil(item: item)
        let nonexistentURL = URL(
            fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "VPlayer-task21-release-boundary-\(UUID().uuidString).m3u8")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonexistentURL.path))
        var installedNonexistentItem = false
        do {
            try driver.install(url: nonexistentURL, identity: item)
            installedNonexistentItem = true
            _ = try await driver.waitUntilReady(item: item)
            XCTFail("无效媒体必须报告固定 itemFailed")
        } catch {
            XCTAssertTrue(installedNonexistentItem,
                          "期望失败必须来自 waitUntilReady，而非 install")
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .itemFailed)
        }
        XCTAssertEqual(driver.activeWaiterCount, 0)
        driver.replaceCurrentItemWithNil(item: item)
        try fixture.teardown()
    }
}
