// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Darwin
import Foundation
import XCTest
import VPlayerCore
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
    var stage: String {
        didSet {
            print("RELEASE_PREPARATION_STAGE stage=\(stage) callerCancelled=\(Task.isCancelled)")
        }
    }
    weak var driver: SystemAVPlayerDriver?
    weak var server: LoopbackHTTPServer?
    var setupGETs: LoopbackAcceptedGETSnapshot?
    var requestedRange: FMP4PresentationRange?
    private var task: Task<Void, Never>?

    init(stage: String) {
        self.stage = stage
        print("RELEASE_PREPARATION_STAGE stage=\(stage) callerCancelled=\(Task.isCancelled)")
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            snapshot(reason: "delayed")
        }
    }

    func reportFailure(_ error: any Error) {
        // Record the caller before cleanup cancels the independent probe task.
        // Preserve the original thrown error and all existing assertions.
        print("RELEASE_PREPARATION_FAILURE stage=\(stage) "
            + "callerCancelled=\(Task.isCancelled) "
            + "isCancellation=\(error is CancellationError) "
            + "errorType=\(String(reflecting: type(of: error))) "
            + "errorFact=\(Self.errorFact(error as NSError))")
        snapshot(reason: "failure")
    }

    private func snapshot(reason: String) {
        let player = driver?.player
        let item = player?.currentItem
        // These bounded test-only facts are read once. Never retain an item,
        // URL, or production callback owner in the suspended probe task.
        let ranges = item?.loadedTimeRanges ?? []
        let first = ranges.count <= 128 ? ranges.first?.timeRangeValue : nil
        let last = ranges.count <= 128 ? ranges.last?.timeRangeValue : nil
        let requests = server?.acceptedGETSnapshot()
        let usage = server?.usage
        print("RELEASE_PREPARATION_WAIT reason=\(reason) stage=\(self.stage) "
            + "waitPhase=\(driver?.prepareWait.activePhase.map { String(describing: $0) } ?? "none") "
            + "playerStatus=\(player?.status.rawValue ?? -1) "
            + "playerError=\(Self.errorFact(player?.error as NSError?)) "
            + "itemStatus=\(item?.status.rawValue ?? -1) "
            + "itemError=\(Self.errorFact(item?.error as NSError?)) "
            + "assetPlayableState=\(Self.playableFact(item)) "
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

    func observeRequests(afterSetup server: LoopbackHTTPServer) {
        self.server = server
        setupGETs = server.acceptedGETSnapshot()
    }

    private static func requestFact(_ snapshot: LoopbackAcceptedGETSnapshot?) -> String {
        guard let snapshot else { return "none" }
        return "playlist:\(snapshot.playlistCount),init:\(snapshot.initializationCount),media:\(snapshot.mediaCount)"
    }

    private static func errorFact(_ error: NSError?) -> String {
        guard let error else { return "none" }
        return "\(String(error.domain.prefix(96))):\(error.code)"
    }

    private static func playableFact(_ item: AVPlayerItem?) -> String {
        guard let item else { return "no_item" }
        // status(of:) only inspects current loading state. Do not call load(_:)
        // here, because that would change the operation this probe observes.
        switch item.asset.status(of: .isPlayable) {
        case .notYetLoaded: return "notYetLoaded"
        case .loading: return "loading"
        case .loaded(let playable): return "loaded:\(playable)"
        case .failed(let error): return "failed:\(errorFact(error))"
        }
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
        var fixture: ReleaseAACPublicationFixture?
        do { fixture = try await .make(lifecycle: lifecycle) }
        catch { probe.reportFailure(error); throw error }
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
        let prepared: PreparedAVPlayerItem
        do { prepared = try await XCTUnwrap(coordinator).prepareCurrentItem() }
        catch { probe.reportFailure(error); throw error }
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
        let fixture: ReleaseAACPublicationFixture
        do { fixture = try await ReleaseAACPublicationFixture.make(lifecycle: lifecycle) }
        catch { probe.reportFailure(error); throw error }
        defer { try? fixture.teardown() }
        probe.observeRequests(afterSetup: fixture.server)
        probe.stage = "loaded.timeline_mapping"
        let playhead: PreparedPlayheadIdentity
        do { playhead = try await fixture.makePreparedPlayhead() }
        catch { probe.reportFailure(error); throw error }
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
        let receipt: AVPlayerLoadedRangeReceipt
        do {
            receipt = try await driver.waitForLoadedTimeRanges(
                item: item, playhead: playhead, covering: ExactMediaInterval(requested))
        } catch { probe.reportFailure(error); throw error }
        probe.stage = "loaded.native_ranges_returned"
        XCTAssertEqual(receipt, .init(item: item, playhead: playhead,
                                      requested: ExactMediaInterval(requested)))
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
        // The missing file-scheme HLS URL stalled even in raw AVPlayer controls.
        // This exact existing 43-byte fixture independently reaches native failure:
        // https://github.com/vForce825/VPlayer/actions/runs/37008106413
        let invalidURL = try ReleaseCorruptMP4ReadinessFixture.create()
        defer {
            driver.replaceCurrentItemWithNil(item: item)
            driver.removeObservers(item: item)
            XCTAssertNoThrow(try FileManager.default.removeItem(at: invalidURL))
        }
        try ReleaseCorruptMP4ReadinessFixture.verify(invalidURL)
        probe.stage = "loaded.invalid_item_ready"
        try driver.install(url: invalidURL, identity: item)
        let invalidItem = try XCTUnwrap(driver.player.currentItem)
        do {
            _ = try await driver.waitUntilReady(item: item)
            XCTFail("Malformed media must report the native item failure")
        } catch {
            probe.reportFailure(error)
            let diagnostic = try XCTUnwrap(error as? ErrorDiagnosticSnapshot)
            let nativeError = try XCTUnwrap(invalidItem.error)
            XCTAssertEqual(diagnostic, PlaybackErrorDiagnostics.snapshot(nativeError))
        }
        XCTAssertTrue(driver.player.currentItem === invalidItem)
        XCTAssertEqual(invalidItem.status, .failed)
        XCTAssertNotNil(invalidItem.error)
        XCTAssertEqual(driver.activeWaiterCount, 0)
        driver.replaceCurrentItemWithNil(item: item)
        driver.removeObservers(item: item)
        try fixture.teardown()
    }
}

private enum ReleaseCorruptMP4ReadinessFixture {
    private static let corruptMP4Bytes = Data("VPlayer deliberately malformed MP4 fixture\n".utf8)

    static func create() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VPlayer-readiness-reference-\(UUID().uuidString).mp4")
        try Self.corruptMP4Bytes.write(to: url, options: .atomic)
        return url
    }

    static func verify(_ url: URL) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let bytes = try Data(contentsOf: url)
        let matches = bytes == Self.corruptMP4Bytes
        print("READINESS_REFERENCE fixture=corrupt_mp4 exists=\(exists) "
            + "bytes=\(bytes.count) contentMatches=\(matches)")
        XCTAssertTrue(exists)
        XCTAssertTrue(matches)
        guard exists, matches else {
            throw NSError(domain: "ReleaseReadinessFixture", code: 1)
        }
    }
}

/// Stores only KVO scalars, never the observed item or its URL.
private final class ReleaseReadinessKVOFacts: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackCount = 0
    private var lastStatus = -1
    private var lastChangeStatus = -1
    private var terminalStatus = -1

    func record(_ status: AVPlayerItem.Status, changeStatus: AVPlayerItem.Status?) -> Bool {
        lock.withLock {
            callbackCount += 1
            lastStatus = status.rawValue
            lastChangeStatus = changeStatus?.rawValue ?? -1
            guard terminalStatus == -1,
                  status == .readyToPlay || status == .failed else { return false }
            terminalStatus = lastStatus
            return true
        }
    }

    var summary: String {
        lock.withLock {
            "kvoCount=\(callbackCount) kvoLastStatus=\(lastStatus) "
                + "kvoLastChangeStatus=\(lastChangeStatus) kvoTerminalStatus=\(terminalStatus)"
        }
    }

    var firstTerminalStatus: Int { lock.withLock { terminalStatus } }
}

@MainActor
private final class ReleaseReadinessTaskProgress {
    var completed = false
}

@MainActor
final class SDKReadinessReferenceReleaseTests: XCTestCase {
    // These independent controls preserve the original 120-second native-test
    // limit. A control must reach its expected terminal result; observing
    // unknown or cancelling a stuck operation is a test failure, never a skip.
    // Prior nonexistent file-scheme .m3u8 controls stayed unknown in both raw
    // players and the driver, while independent isPlayable returned true:
    // https://github.com/vForce825/VPlayer/actions/runs/37005698567
    // That HLS URL shape and suitability query are not file-readability oracles.
    // The byte-verified malformed file reached native failure in run37008106413.
    private let observationTimeout: TimeInterval = 15

    func testObservedStatusDrivesTerminalWhenTypedChangeValueIsAbsent() {
        let facts = ReleaseReadinessKVOFacts()
        XCTAssertFalse(facts.record(.unknown, changeStatus: nil))
        XCTAssertTrue(facts.record(.failed, changeStatus: nil))
        XCTAssertEqual(facts.firstTerminalStatus, AVPlayerItem.Status.failed.rawValue)
        XCTAssertFalse(facts.record(.failed, changeStatus: .failed))
    }

    func testRawCorruptMP4ObservedBeforeAttachmentFails() async throws {
        try await checkRawCorruptMP4(observeBeforeAttachment: true)
    }

    func testRawCorruptMP4ObservedAfterAttachmentFails() async throws {
        try await checkRawCorruptMP4(observeBeforeAttachment: false)
    }

    private func checkRawCorruptMP4(observeBeforeAttachment: Bool) async throws {
        let label = observeBeforeAttachment ? "raw.before_attach" : "raw.after_attach"
        let url = try ReleaseCorruptMP4ReadinessFixture.create()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: url)) }
        try ReleaseCorruptMP4ReadinessFixture.verify(url)
        let player = AVPlayer()
        let item = AVPlayerItem(url: url)
        // Match install's media settings in both references. Only KVO ordering
        // differs; neither reference creates a driver, log reader, or event hub.
        player.pause()
        player.automaticallyWaitsToMinimizeStalling = true
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        let terminal = expectation(description: "\(label) corrupt MP4 reaches terminal status")
        let facts = ReleaseReadinessKVOFacts()
        var observation: NSKeyValueObservation?
        defer {
            observation?.invalidate()
            player.replaceCurrentItem(with: nil)
        }
        let observe = {
            item.observe(\.status, options: [.initial, .new]) { observed, change in
                // The typed enum newValue was nil even for the initial callback
                // on tvOS27. Read the observed status as the production waiter does.
                if facts.record(observed.status, changeStatus: change.newValue) {
                    terminal.fulfill()
                }
            }
        }
        if observeBeforeAttachment { observation = observe() }
        player.replaceCurrentItem(with: item)
        if !observeBeforeAttachment { observation = observe() }
        print("READINESS_REFERENCE stage=\(label).attached \(facts.summary)")

        await fulfillment(of: [terminal], timeout: observationTimeout)
        print("READINESS_REFERENCE stage=\(label).observed \(Self.playerFact(player)) \(facts.summary)")
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.timeControlStatus, .paused)
        XCTAssertEqual(facts.firstTerminalStatus, AVPlayerItem.Status.failed.rawValue)
        XCTAssertEqual(item.status, .failed, "Malformed MP4 bytes must fail, not become ready")
        XCTAssertNotNil(item.error)
    }

    func testFreshDriverCorruptMP4Fails() async throws {
        let url = try ReleaseCorruptMP4ReadinessFixture.create()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: url)) }
        try ReleaseCorruptMP4ReadinessFixture.verify(url)
        let allocator = PlaybackIdentityAllocator()
        let lifecycle = try ReleaseIdentityFixture.lifecycle(using: allocator)
        let identity = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: try allocator.next(in: .outputItem))
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer())
        try driver.install(url: url, identity: identity)
        defer {
            driver.replaceCurrentItemWithNil(item: identity)
            driver.removeObservers(item: identity)
        }
        let item = try XCTUnwrap(driver.player.currentItem)
        let terminal = expectation(description: "Fresh driver rejects malformed MP4 bytes")
        let progress = ReleaseReadinessTaskProgress()
        let task = Task { @MainActor in
            let result: Result<AVPlayerItemInstanceIdentity, Error>
            do { result = .success(try await driver.waitUntilReady(item: identity)) }
            catch { result = .failure(error) }
            progress.completed = true
            terminal.fulfill()
            return result
        }
        defer { task.cancel() }

        await fulfillment(of: [terminal], timeout: observationTimeout)
        let completedBeforeCancellation = progress.completed
        print("READINESS_REFERENCE stage=driver.observed \(Self.playerFact(driver.player)) "
            + "completedBeforeCancellation=\(completedBeforeCancellation) "
            + "waitPhase=\(driver.prepareWait.activePhase.map { String(describing: $0) } ?? "none") "
            + "waiterCount=\(driver.activeWaiterCount)")
        // Join the owned operation before releasing the driver. The production
        // wait has a cancellation handler; the outer XCTest limit still applies.
        task.cancel()
        let result = await task.value
        XCTAssertTrue(completedBeforeCancellation)
        XCTAssertEqual(item.status, .failed)
        XCTAssertNotNil(item.error)
        XCTAssertEqual(driver.rate, 0)
        XCTAssertEqual(driver.timeControlStatus, .paused)
        XCTAssertEqual(driver.activeWaiterCount, 0)
        switch result {
        case .success:
            XCTFail("Malformed MP4 bytes must not produce a ready identity")
        case .failure(let error):
            print("READINESS_REFERENCE stage=driver.returned error=\(Self.errorFact(error as NSError))")
            XCTAssertFalse(error is CancellationError,
                           "Diagnostic cancellation is not native item failure")
            let nativeError = try XCTUnwrap(item.error)
            XCTAssertEqual(PlaybackErrorDiagnostics.snapshot(error),
                           PlaybackErrorDiagnostics.snapshot(nativeError),
                           "The wait must report this item's native failure")
        }
    }

    func testIndependentCorruptMP4DurationLoadFails() async throws {
        // A separate asset and URL prevent this explicit load from preparing
        // an item in another control. Asset loading is not item readiness.
        let url = try ReleaseCorruptMP4ReadinessFixture.create()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: url)) }
        try ReleaseCorruptMP4ReadinessFixture.verify(url)
        let asset = AVURLAsset(url: url)
        let terminal = expectation(description: "Malformed MP4 duration load fails")
        let progress = ReleaseReadinessTaskProgress()
        let task = Task { @MainActor in
            let result: Result<CMTime, Error>
            do { result = .success(try await asset.load(.duration)) }
            catch { result = .failure(error) }
            progress.completed = true
            terminal.fulfill()
            return result
        }
        defer { task.cancel(); asset.cancelLoading() }

        await fulfillment(of: [terminal], timeout: observationTimeout)
        let completedBeforeCancellation = progress.completed
        print("READINESS_REFERENCE stage=asset.observed "
            + "assetDurationState=\(Self.durationFact(asset)) "
            + "completedBeforeCancellation=\(completedBeforeCancellation)")
        // cancelLoading is the asset's supported physical cancellation API.
        // Join even after a diagnostic timeout. If SDK cancellation cannot
        // complete, the original outer XCTest timeout remains authoritative.
        asset.cancelLoading()
        task.cancel()
        let result = await task.value
        XCTAssertTrue(completedBeforeCancellation)
        switch result {
        case .success(let duration):
            XCTFail("Malformed MP4 unexpectedly loaded duration=\(Self.timeFact(duration))")
        case .failure(let error):
            print("READINESS_REFERENCE stage=asset.returned error=\(Self.errorFact(error as NSError))")
            XCTAssertFalse(error is CancellationError,
                           "Diagnostic cancellation is not native asset failure")
        }
    }

    private static func durationFact(_ asset: AVAsset) -> String {
        switch asset.status(of: .duration) {
        case .notYetLoaded: return "notYetLoaded"
        case .loading: return "loading"
        case .loaded(let time): return "loaded:\(timeFact(time))"
        case .failed(let error): return "failed:\(errorFact(error))"
        }
    }

    private static func timeFact(_ time: CMTime) -> String {
        "\(time.value)/\(time.timescale):flags\(time.flags.rawValue)"
    }

    private static func playerFact(_ player: AVPlayer) -> String {
        let item = player.currentItem
        return "playerStatus=\(player.status.rawValue) playerError=\(errorFact(player.error as NSError?)) "
            + "itemStatus=\(item?.status.rawValue ?? -1) itemError=\(errorFact(item?.error as NSError?)) "
            + "assetPlayableState=\(item.map { playableFact($0.asset) } ?? "no_item") "
            + "rate=\(player.rate) timeControlStatus=\(player.timeControlStatus.rawValue) "
            + "disconnected=\(player.disconnectedFromSystemAudio)"
    }

    private static func playableFact(_ asset: AVAsset) -> String {
        switch asset.status(of: .isPlayable) {
        case .notYetLoaded: return "notYetLoaded"
        case .loading: return "loading"
        case .loaded(let value): return "loaded:\(value)"
        case .failed(let error): return "failed:\(errorFact(error))"
        }
    }

    private static func errorFact(_ error: NSError?) -> String {
        guard let error else { return "none" }
        return "\(String(error.domain.prefix(96))):\(error.code)"
    }
}
