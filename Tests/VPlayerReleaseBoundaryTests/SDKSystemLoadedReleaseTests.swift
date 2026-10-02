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
private final class ReleasePreparationProgressProbe {
    var stage: String
    weak var driver: SystemAVPlayerDriver?
    weak var server: LoopbackHTTPServer?
    var setupGETs: LoopbackAcceptedGETSnapshot?
    var requestedRange: FMP4PresentationRange?
    private var task: Task<Void, Never>?

    init(stage: String) {
        self.stage = stage
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            let player = driver?.player
            // These bounded test-only facts are read once. Never retain an item,
            // URL, or production callback owner in the suspended probe task.
            let ranges = player?.currentItem?.loadedTimeRanges ?? []
            let first = ranges.count <= 128 ? ranges.first?.timeRangeValue : nil
            let last = ranges.count <= 128 ? ranges.last?.timeRangeValue : nil
            let requests = server?.acceptedGETSnapshot()
            let usage = server?.usage
            print("RELEASE_PREPARATION_WAIT stage=\(self.stage) "
                + "waitPhase=\(driver?.prepareWait.activePhase.map { String(describing: $0) } ?? "none") "
                + "itemStatus=\(player?.currentItem?.status.rawValue ?? -1) "
                + "timeControlStatus=\(player?.timeControlStatus.rawValue ?? -1) "
                + "rangeCount=\(ranges.count) "
                + "firstStart=\(Self.timeFact(first?.start)) "
                + "firstDuration=\(Self.timeFact(first?.duration)) "
                + "lastStart=\(Self.timeFact(last?.start)) "
                + "lastDuration=\(Self.timeFact(last?.duration)) "
                + "requestedStart=\(Self.timeFact(requestedRange?.start.cmTime)) "
                + "requestedDuration=\(Self.timeFact(requestedRange?.duration.cmTime)) "
                + "disconnected=\(driver?.disconnectedFromSystemAudio ?? false) "
                + "waiterCount=\(driver?.activeWaiterCount ?? 0) "
                + "setupGETs=\(Self.requestFact(setupGETs)) "
                + "currentGETs=\(Self.requestFact(requests)) "
                + "connections=\(usage?.connections ?? -1) "
                + "activeResponses=\(usage?.activeResponses ?? -1) "
                + "contextBytes=\(PlaybackResourceContextLedger.shared.chargedBytes)")
        }
    }

    func observeRequests(afterSetup server: LoopbackHTTPServer) {
        self.server = server
        setupGETs = server.acceptedGETSnapshot()
    }

    private static func requestFact(_ snapshot: LoopbackAcceptedGETSnapshot?) -> String {
        guard let snapshot else { return "none" }
        return "playlist:\(snapshot.playlistCount),init:\(snapshot.initializationCount),media:\(snapshot.mediaCount)"
    }

    private static func timeFact(_ time: CMTime?) -> String {
        guard let time else { return "none" }
        return "\(time.value)/\(time.timescale):flags\(time.flags.rawValue)"
    }

    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
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
        let probe = ReleasePreparationProgressProbe(stage: "scoped.fixture")
        defer { probe.cancel() }
        let allocator = PlaybackIdentityAllocator()
        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: allocator)
        var fixture: ReleaseAACPublicationFixture? = try await .make(lifecycle: lifecycle)
        defer { try? fixture?.teardown() }
        probe.observeRequests(afterSetup: try XCTUnwrap(fixture).server)
        let item = try XCTUnwrap(fixture).request.item
        var driver: SystemAVPlayerDriver? = try .make(player: AVPlayer())
        probe.driver = driver
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
        probe.stage = "scoped.coordinator_prepare"
        print("TASK21_RELEASE_RUNTIME stage=prepare-begin")
        let prepared = try await XCTUnwrap(coordinator).prepareCurrentItem()
        print("TASK21_RELEASE_RUNTIME stage=prepare-returned")
        probe.cancel()

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
        let probe = ReleasePreparationProgressProbe(stage: "loaded.fixture")
        defer { probe.cancel() }
        let allocator = PlaybackIdentityAllocator()
        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: allocator)
        let fixture = try await ReleaseAACPublicationFixture.make(lifecycle: lifecycle)
        defer { try? fixture.teardown() }
        probe.observeRequests(afterSetup: fixture.server)
        probe.stage = "loaded.timeline_mapping"
        let playhead = try await fixture.makePreparedPlayhead()
        let item = fixture.request.item
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer())
        probe.driver = driver
        try driver.install(url: fixture.request.itemURL, identity: item)
        defer { driver.replaceCurrentItemWithNil(item: item) }

        let requested = try FMP4PresentationRange(
            start: playhead.playerItemTime,
            duration: ExactMediaTime(value: 1, timescale: 100))
        probe.requestedRange = requested
        probe.stage = "loaded.native_ranges"
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
        probe.stage = "loaded.invalid_item_ready"
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
