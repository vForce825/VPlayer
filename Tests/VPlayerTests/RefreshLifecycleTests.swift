// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer
@testable import VPlayerCore

@MainActor
final class RefreshLifecycleTests: XCTestCase {
    func testForegroundActivationReplacesAndDeactivationCancelsTheLoopTask() async {
        let probe = ForegroundLoopProbe()
        let driver = ForegroundRefreshDriver(
            loadProfiles: { [] },
            refresh: { _, _, _ in [] },
            now: Date.init,
            sleep: {
                await probe.recordSleepStarted()
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    await probe.recordCancellation()
                    throw error
                }
            },
            reportStatus: { _ in }
        )

        driver.initialLibraryLoadDidComplete()
        driver.activate()
        await probe.waitForSleepCount(1)
        driver.activate()
        await probe.waitForCancellationCount(1)
        await probe.waitForSleepCount(2)
        driver.deactivate()
        await probe.waitForCancellationCount(2)

        let cancellationCount = await probe.cancellationCount
        XCTAssertEqual(cancellationCount, 2)
    }

    func testForegroundReplacementDoesNotReportLoadErrorFromCancelledLoop() async {
        let loadGate = ForegroundLoadFailureGate()
        var reportedStatuses: [String] = []
        let driver = ForegroundRefreshDriver(
            loadProfiles: {
                try await loadGate.load()
            },
            refresh: { _, _, _ in [] },
            sleep: {
                try await Task.sleep(for: .seconds(3_600))
            },
            reportStatus: { message in
                reportedStatuses.append(message)
            }
        )

        driver.initialLibraryLoadDidComplete()
        driver.activate()
        await loadGate.waitForLoadCount(1)
        driver.activate()
        await loadGate.waitForLoadCount(2)
        await loadGate.failFirstLoad()
        await loadGate.waitUntilFirstLoadReturned()
        for _ in 0..<100 {
            await Task.yield()
        }
        driver.deactivate()

        XCTAssertEqual(reportedStatuses, [])
    }

    func testForegroundProfileLoadFailureKeepsOriginalTypeAndReasonWithoutPrivateAddresses() async {
        let probe = ForegroundLoopProbe()
        let failure = NSError(
            domain: "Lifecycle.ProfileLoad",
            code: -412,
            userInfo: [NSLocalizedDescriptionKey:
                "配置读取原始失败 https://private.example/config?token=secret /private/source.sqlite password=secret"]
        )
        var reportedStatuses: [String] = []
        let driver = ForegroundRefreshDriver(
            loadProfiles: { throw failure },
            refresh: { _, _, _ in [] },
            sleep: {
                await probe.recordSleepStarted()
                try await Task.sleep(for: .seconds(3_600))
            },
            reportStatus: { reportedStatuses.append($0) }
        )
        defer { driver.deactivate() }

        driver.initialLibraryLoadDidComplete()
        driver.activate()
        await probe.waitForSleepCount(1)

        XCTAssertEqual(reportedStatuses.count, 1)
        let message = reportedStatuses.first ?? ""
        XCTAssertTrue(message.contains("NSError"))
        XCTAssertTrue(message.contains("Lifecycle.ProfileLoad"))
        XCTAssertTrue(message.contains("-412"))
        XCTAssertTrue(message.contains("配置读取原始失败"))
        XCTAssertFalse(message.contains("private.example"))
        XCTAssertFalse(message.contains("/private/source.sqlite"))
        XCTAssertFalse(message.contains("password=secret"))
    }

    func testForegroundActivationWaitsForInitialLibraryLoadBeforeStartingLoop() async {
        let probe = ForegroundLoopProbe()
        let driver = ForegroundRefreshDriver(
            loadProfiles: { [] },
            refresh: { _, _, _ in [] },
            sleep: {
                await probe.recordSleepStarted()
                try await Task.sleep(for: .seconds(3_600))
            },
            reportStatus: { _ in }
        )

        driver.activate()
        for _ in 0..<100 {
            await Task.yield()
        }
        let sleepCountBeforeInitialLoad = await probe.sleepCountValue()
        XCTAssertEqual(sleepCountBeforeInitialLoad, 0)

        driver.initialLibraryLoadDidComplete()
        await probe.waitForSleepCount(1)
        let sleepCountAfterInitialLoad = await probe.sleepCountValue()
        XCTAssertEqual(sleepCountAfterInitialLoad, 1)
        driver.deactivate()
    }

    func testInitialLibraryLoadCompletionWhileInactiveWaitsForActivation() async {
        let probe = ForegroundLoopProbe()
        let driver = ForegroundRefreshDriver(
            loadProfiles: { [] },
            refresh: { _, _, _ in [] },
            sleep: {
                await probe.recordSleepStarted()
                try await Task.sleep(for: .seconds(3_600))
            },
            reportStatus: { _ in }
        )

        driver.initialLibraryLoadDidComplete()
        for _ in 0..<100 {
            await Task.yield()
        }
        let sleepCountWhileInactive = await probe.sleepCountValue()
        XCTAssertEqual(sleepCountWhileInactive, 0)

        driver.activate()
        await probe.waitForSleepCount(1)
        let sleepCountAfterActivation = await probe.sleepCountValue()
        XCTAssertEqual(sleepCountAfterActivation, 1)
        driver.deactivate()
    }

    func testReducedResourcePreferencePreservesManualRefreshWhileAutomaticWorkIsDeferred() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let work = BackgroundWorkProbe()
        let sleeping = expectation(description: "Reduced foreground loop reached its normal sleep")
        let automaticLoad = expectation(description: "Preference changes must not load foreground profiles")
        automaticLoad.isInverted = true
        let refresh: ForegroundRefreshDriver.Refresh = { profileID, resources, trigger in
            XCTAssertEqual(profileID, profile.id)
            await work.recordRefresh(resources: resources, trigger: trigger)
            return resources.map { RefreshOutcome(resource: $0, succeeded: true, message: nil) }
        }
        let driver = ForegroundRefreshDriver(
            loadProfiles: { automaticLoad.fulfill(); return [profile] },
            refresh: refresh,
            now: { now },
            sleep: { sleeping.fulfill(); try await Task.sleep(for: .seconds(3_600)) },
            reportStatus: { _ in XCTFail("No automatic refresh error is expected") }
        )
        defer { driver.deactivate() }
        let scheduler = BackgroundSchedulerSpy()
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { [profile] }, refresh: refresh,
            now: { now }, reportStatus: { _ in XCTFail("Background deferral should succeed") }
        )
        let model = AppModel(
            repository: RepositorySpy(profiles: [profile]), refresh: refresh, now: { now }
        )
        driver.setPrefersReducedResourceUsage(true)
        registrar.setPrefersReducedResourceUsage(true)
        driver.initialLibraryLoadDidComplete()
        driver.activate()
        registrar.register()
        let completed = expectation(description: "Reduced background launch completed")
        let backgroundTask = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { success in XCTAssertTrue(success); completed.fulfill() }
        )
        try scheduler.launch(backgroundTask)
        await fulfillment(of: [sleeping, completed], timeout: 2)
        let automaticRefreshCount = await work.refreshCount
        XCTAssertEqual(automaticRefreshCount, 0)

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .epg)

        let resources = await work.resources
        let trigger = await work.trigger
        let refreshCount = await work.refreshCount
        XCTAssertEqual(resources, [.epg])
        XCTAssertEqual(refreshCount, 1)
        guard case .manual? = trigger else { return XCTFail("Expected only the requested manual refresh") }
        XCTAssertEqual(scheduler.submissions.map(\.earliestBeginDate), [now.addingTimeInterval(3_600)])

        let unexpectedScheduling = expectation(description: "Preference changes must not resubmit or cancel")
        unexpectedScheduling.isInverted = true
        scheduler.onMutation = { unexpectedScheduling.fulfill() }
        driver.setPrefersReducedResourceUsage(false)
        registrar.setPrefersReducedResourceUsage(false)
        driver.setPrefersReducedResourceUsage(true)
        registrar.setPrefersReducedResourceUsage(true)
        await fulfillment(of: [automaticLoad, unexpectedScheduling], timeout: 0.05)
        let finalRefreshCount = await work.refreshCount
        XCTAssertEqual(finalRefreshCount, 1)
    }

    func testReducedResourceBackgroundLaunchDefersOneHourThenNormalLaunchRefreshesDueWork() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        defer { scheduler.completeAsyncSubmission() }
        let submitted = expectation(description: "Reduced successor submission entered")
        scheduler.onSubmission = { submitted.fulfill() }
        let work = BackgroundWorkProbe()
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { [profile] },
            refresh: { _, resources, trigger in
                await work.recordRefresh(resources: resources, trigger: trigger)
                return resources.map { RefreshOutcome(resource: $0, succeeded: true, message: nil) }
            },
            now: { now }, reportStatus: { _ in XCTFail("Scheduling should succeed") }
        )
        registrar.setPrefersReducedResourceUsage(true)
        registrar.register()
        var completions: [Bool] = []
        let deferred = expectation(description: "Reduced launch completed after successor submission")
        let reducedTask = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { success in completions.append(success); deferred.fulfill() }
        )
        try scheduler.launch(reducedTask)
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertTrue(completions.isEmpty, "The launch must wait for physical successor submission")
        XCTAssertEqual(scheduler.events, [.cancel, .begin(now.addingTimeInterval(3_600))])
        scheduler.completeAsyncSubmission()
        await fulfillment(of: [deferred], timeout: 2)
        XCTAssertEqual(completions, [true])
        let reducedRefreshCount = await work.refreshCount
        XCTAssertEqual(reducedRefreshCount, 0)
        XCTAssertEqual(scheduler.pendingSubmission?.earliestBeginDate, now.addingTimeInterval(3_600))

        scheduler.onSubmission = nil
        let preferenceOnlyMutation = expectation(description: "Preference changes alone must preserve pending work")
        preferenceOnlyMutation.isInverted = true
        scheduler.onMutation = { preferenceOnlyMutation.fulfill() }
        registrar.setPrefersReducedResourceUsage(false)
        await fulfillment(of: [preferenceOnlyMutation], timeout: 0.05)
        let recoveredRefreshCount = await work.refreshCount
        XCTAssertEqual(recoveredRefreshCount, 0, "Only a legitimate launch may resume automatic refresh")
        XCTAssertEqual(scheduler.pendingSubmission?.earliestBeginDate, now.addingTimeInterval(3_600))

        scheduler.onMutation = nil
        scheduler.holdsAsyncSubmission = false
        let refreshed = expectation(description: "Normal background launch completed")
        let normalTask = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { success in completions.append(success); refreshed.fulfill() }
        )
        try scheduler.launch(normalTask)
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(completions, [true, true])
        XCTAssertEqual(scheduler.submissions.map(\.earliestBeginDate), [
            now.addingTimeInterval(3_600), now.addingTimeInterval(15 * 60),
        ])
        XCTAssertEqual(scheduler.cancelledIdentifiers, Array(repeating: BackgroundRefreshRegistrar.identifier, count: 2))
        XCTAssertEqual(scheduler.maximumInFlightSubmissions, 1)
        let resources = await work.resources
        let trigger = await work.trigger
        let refreshCount = await work.refreshCount
        XCTAssertEqual(resources, [.playlist])
        XCTAssertEqual(refreshCount, 1)
        guard case .background? = trigger else { return XCTFail("Expected restored background refresh") }
    }

    func testReducedResourceBackgroundSchedulePreservesAnAlreadyLaterPlannerDate() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var profile = makeProfile(now: now)
        profile.m3uRefreshInterval = .sixHours
        profile.m3uStatus.lastSuccessAt = now
        let scheduledProfile = profile
        let scheduler = BackgroundSchedulerSpy()
        let submitted = expectation(description: "Later planner date physically submitted")
        scheduler.onSubmissionCompleted = { submitted.fulfill() }
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { [scheduledProfile] },
            refresh: { _, _, _ in XCTFail("Scheduling must not perform a refresh"); return [] },
            now: { now }, reportStatus: { _ in XCTFail("Scheduling should succeed") }
        )
        registrar.setPrefersReducedResourceUsage(true)
        registrar.scheduleNext()
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(scheduler.submissions.map(\.earliestBeginDate), [now.addingTimeInterval(6 * 3_600)])
        XCTAssertEqual(scheduler.maximumInFlightSubmissions, 1)
    }

    func testNewScheduleWaitsForOldPhysicalSubmissionBeforeReplacingIt() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { [profile] },
            refresh: { _, _, _ in [] }, now: { now }, reportStatus: { _ in }
        )
        registrar.scheduleNext()
        await eventually { scheduler.asyncSubmissionCount == 1 || !scheduler.submissions.isEmpty }
        registrar.scheduleNext()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(scheduler.asyncSubmissionCount, 1, "Native submission must remain serialized")
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.asyncSubmissionCount == 2 || scheduler.submissions.count == 2 }
        XCTAssertEqual(scheduler.asyncSubmissionCount, 2)
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.submissions.count == 2 }
        XCTAssertEqual(scheduler.maximumInFlightSubmissions, 1)
    }

    func testBackgroundSchedulingAwaitsNativeAsyncSubmission() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { [profile] },
            refresh: { _, _, _ in [] }, now: { now }, reportStatus: { _ in }
        )
        registrar.scheduleNext()
        await eventually { scheduler.asyncSubmissionCount == 1 || !scheduler.submissions.isEmpty }
        XCTAssertEqual(scheduler.asyncSubmissionCount, 1)
        XCTAssertTrue(scheduler.submissions.isEmpty, "Submission must await the native async completion")
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.submissions.count == 1 }
        XCTAssertEqual(scheduler.submissions.count, 1)
    }

    func testPreExpiredLaunchPreservesHeldNativeSubmissionAndDoesNoWork() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        let loads = BackgroundLoadProbe()
        let work = BackgroundWorkProbe()
        var completions: [Bool] = []
        let bridge = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { completions.append($0) }
        )
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { await loads.recordLoad(); return [profile] },
            refresh: { _, resources, trigger in
                await work.recordRefresh(resources: resources, trigger: trigger)
                return []
            },
            now: { now }, reportStatus: { _ in }
        )
        registrar.register()
        registrar.scheduleNext()
        await eventually { scheduler.asyncSubmissionCount == 1 }

        bridge.systemDidExpire()
        try scheduler.launch(bridge)
        XCTAssertEqual(completions, [false])
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.inFlightSubmissions == 0 }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(scheduler.pendingSubmission, scheduler.submissions.first)
        XCTAssertNotNil(scheduler.pendingSubmission)
        XCTAssertEqual(scheduler.cancelledIdentifiers.count, 1)
        XCTAssertEqual(scheduler.asyncSubmissionCount, 1)
        XCTAssertEqual(scheduler.maximumInFlightSubmissions, 1)
        let loadCount = await loads.loadCount
        let refreshedResources = await work.resources
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(refreshedResources.isEmpty)
        XCTAssertEqual(completions, [false])
    }

    func testPreExpiredLaunchDoesNotInvalidateAnAwaitedProfileLoad() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let gate = BackgroundProfileLoadGate(
            profiles: [[makeProfile(now: now)]], heldLoads: [1]
        )
        let scheduler = BackgroundSchedulerSpy()
        var completions: [Bool] = []
        let bridge = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { completions.append($0) }
        )
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { try await gate.load() },
            refresh: { _, _, _ in [] }, now: { now }, reportStatus: { _ in }
        )
        registrar.register()
        registrar.scheduleNext()
        await waitForLoadCount(1, gate: gate)
        bridge.systemDidExpire()
        try scheduler.launch(bridge)
        await gate.completeLoad(1)
        await eventually { scheduler.pendingSubmission != nil }

        let loadCount = await gate.loadCount
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(completions, [false])
        XCTAssertEqual(scheduler.asyncSubmissionCount, 1)
        XCTAssertEqual(scheduler.pendingSubmission?.earliestBeginDate, now.addingTimeInterval(15 * 60))
    }

    func testExpiryDuringProfileLoadPreservesPreviousNativeSuccess() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let gate = BackgroundProfileLoadGate(profiles: [[profile], [profile]], heldLoads: [2])
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        var statuses: [String] = []
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { try await gate.load() },
            refresh: { _, _, _ in XCTFail("Expired execution must not refresh"); return [] },
            now: { now }, reportStatus: { statuses.append($0) }
        )
        registrar.register()
        registrar.scheduleNext()
        await eventually { scheduler.asyncSubmissionCount == 1 }
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        await waitForLoadCount(2, gate: gate)
        task.expire()
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.inFlightSubmissions == 0 }
        await gate.completeLoad(2)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(scheduler.asyncSubmissionCount, 1)
        XCTAssertEqual(scheduler.cancelledIdentifiers.count, 1)
        XCTAssertEqual(scheduler.pendingSubmission, scheduler.submissions.first)
        XCTAssertNotNil(scheduler.pendingSubmission)
        XCTAssertTrue(statuses.isEmpty)
    }

    func testExpiryWhileWaitingForPhysicalSlotPreservesPreviousNativeSuccess() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let loads = BackgroundLoadProbe()
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { await loads.recordLoad(); return [profile] },
            refresh: { _, _, _ in XCTFail("Expired execution must not refresh"); return [] },
            now: { now }, reportStatus: { _ in }
        )
        registrar.register()
        registrar.scheduleNext()
        await eventually { scheduler.asyncSubmissionCount == 1 }
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        for _ in 0..<1_000 {
            if await loads.loadCount == 2 { break }
            await Task.yield()
        }
        for _ in 0..<100 { await Task.yield() }
        task.expire()
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.inFlightSubmissions == 0 }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(scheduler.asyncSubmissionCount, 1)
        XCTAssertEqual(scheduler.cancelledIdentifiers.count, 1)
        XCTAssertEqual(scheduler.pendingSubmission, scheduler.submissions.first)
        XCTAssertNotNil(scheduler.pendingSubmission)
    }

    func testHeldSubmissionCoalescesToLatestProfileSnapshotWithoutCancellingNewPendingRequest() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var laterProfile = makeProfile(now: now)
        laterProfile.m3uStatus.lastSuccessAt = now
        let gate = BackgroundProfileLoadGate(
            profiles: [[makeProfile(now: now)], [], [laterProfile]], heldLoads: [2]
        )
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { try await gate.load() },
            refresh: { _, _, _ in [] }, now: { now }, reportStatus: { _ in }
        )
        registrar.scheduleNext()
        await eventually { scheduler.asyncSubmissionCount == 1 }
        registrar.scheduleNext()
        await waitForLoadCount(2, gate: gate)
        registrar.scheduleNext()
        await waitForLoadCount(3, gate: gate)
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.asyncSubmissionCount == 2 }
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.inFlightSubmissions == 0 }
        let newestPending = scheduler.pendingSubmission
        await gate.completeLoad(2)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(scheduler.asyncSubmissionCount, 2)
        XCTAssertEqual(scheduler.maximumInFlightSubmissions, 1)
        XCTAssertEqual(scheduler.pendingSubmission, newestPending)
        XCTAssertEqual(newestPending?.earliestBeginDate, now.addingTimeInterval(60 * 60))
        XCTAssertEqual(scheduler.events, [
            .cancel, .begin(now.addingTimeInterval(15 * 60)), .succeed(now.addingTimeInterval(15 * 60)),
            .cancel, .begin(now.addingTimeInterval(60 * 60)), .succeed(now.addingTimeInterval(60 * 60))
        ])
    }

    func testNativeFailureSettlesBeforeLatestSuccessorSubmits() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        var statuses: [String] = []
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { [profile] },
            refresh: { _, _, _ in [] }, now: { now }, reportStatus: { statuses.append($0) }
        )
        registrar.scheduleNext()
        await eventually { scheduler.asyncSubmissionCount == 1 }
        registrar.scheduleNext()
        scheduler.completeAsyncSubmission(error: LifecycleTestError.loadFailed)
        await eventually { scheduler.asyncSubmissionCount == 2 }
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.inFlightSubmissions == 0 }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(scheduler.maximumInFlightSubmissions, 1)
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertEqual(scheduler.pendingSubmission, scheduler.submissions.last)
        XCTAssertNotNil(scheduler.pendingSubmission)
        XCTAssertTrue(statuses.isEmpty, "Superseded native failures must not report current errors")
    }

    func testLatestEmptyProfilesCancelOldPendingRequestOnlyAfterNativeSettlement() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let gate = BackgroundProfileLoadGate(profiles: [[makeProfile(now: now)], []])
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { try await gate.load() },
            refresh: { _, _, _ in [] }, now: { now }, reportStatus: { _ in }
        )
        registrar.scheduleNext()
        await eventually { scheduler.asyncSubmissionCount == 1 }
        registrar.scheduleNext()
        await waitForLoadCount(2, gate: gate)
        XCTAssertEqual(scheduler.cancelledIdentifiers.count, 1)
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.cancelledIdentifiers.count == 2 }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertNil(scheduler.pendingSubmission)
        XCTAssertEqual(scheduler.asyncSubmissionCount, 1)
        XCTAssertEqual(scheduler.events, [
            .cancel, .begin(now.addingTimeInterval(15 * 60)), .succeed(now.addingTimeInterval(15 * 60)), .cancel
        ])
    }

    func testExpiryDoesNotReleaseNativeSlotBeforeLatestSuccessorCanReplaceIt() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var laterProfile = makeProfile(now: now)
        laterProfile.m3uStatus.lastSuccessAt = now
        let gate = BackgroundProfileLoadGate(profiles: [[makeProfile(now: now)], [laterProfile]])
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { try await gate.load() },
            refresh: { _, _, _ in XCTFail("Expired execution must not refresh"); return [] },
            now: { now }, reportStatus: { _ in }
        )
        registrar.register()
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        await eventually { scheduler.asyncSubmissionCount == 1 }
        task.expire()
        registrar.scheduleNext()
        await waitForLoadCount(2, gate: gate)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(scheduler.inFlightSubmissions, 1)
        XCTAssertEqual(scheduler.asyncSubmissionCount, 1)

        scheduler.completeAsyncSubmission()
        await eventually { scheduler.asyncSubmissionCount == 2 }
        scheduler.completeAsyncSubmission()
        await eventually { scheduler.inFlightSubmissions == 0 }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(scheduler.maximumInFlightSubmissions, 1)
        XCTAssertEqual(scheduler.pendingSubmission?.earliestBeginDate, now.addingTimeInterval(60 * 60))
        XCTAssertEqual(scheduler.events, [
            .cancel, .begin(now.addingTimeInterval(15 * 60)), .succeed(now.addingTimeInterval(15 * 60)),
            .cancel, .begin(now.addingTimeInterval(60 * 60)), .succeed(now.addingTimeInterval(60 * 60))
        ])
    }

    func testExpiredNativeFailureDoesNotReportStatusOrRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        scheduler.holdsAsyncSubmission = true
        var statuses: [String] = []
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { [profile] },
            refresh: { _, _, _ in XCTFail("Expired execution must not refresh"); return [] },
            now: { now }, reportStatus: { statuses.append($0) }
        )
        registrar.register()
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        await eventually { scheduler.asyncSubmissionCount == 1 }
        task.expire()
        scheduler.completeAsyncSubmission(error: LifecycleTestError.loadFailed)
        await eventually { scheduler.inFlightSubmissions == 0 }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(task.completions, [false])
        XCTAssertNil(scheduler.pendingSubmission)
        XCTAssertTrue(statuses.isEmpty)
    }

    func testExpiredProfileLoadFailureDoesNotReportStatus() async throws {
        let gate = BackgroundProfileLoadGate(profiles: [[]], heldLoads: [1])
        let scheduler = BackgroundSchedulerSpy()
        var statuses: [String] = []
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler, loadProfiles: { try await gate.load() },
            refresh: { _, _, _ in [] }, reportStatus: { statuses.append($0) }
        )
        registrar.register()
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        await waitForLoadCount(1, gate: gate)
        task.expire()
        await gate.completeLoad(1, error: LifecycleTestError.loadFailed)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(task.completions, [false])
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(scheduler.asyncSubmissionCount, 0)
    }

    func testBackgroundRegistrationIsIdempotentAndSchedulesBeforeRefreshing() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        let probe = BackgroundWorkProbe()
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { [profile] },
            refresh: { _, resources, trigger in
                await probe.recordRefresh(resources: resources, trigger: trigger)
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: true, message: nil)
                }
            },
            now: { now },
            reportStatus: { _ in }
        )

        registrar.register()
        registrar.register()
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        await probe.waitUntilRefreshed()
        await eventually { task.completions.count == 1 }

        let refreshedResources = await probe.resources
        let refreshTrigger = await probe.trigger

        XCTAssertEqual(scheduler.registrationCount, 1)
        XCTAssertEqual(scheduler.cancelledIdentifiers, [BackgroundRefreshRegistrar.identifier])
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertEqual(scheduler.submissions.first?.identifier, BackgroundRefreshRegistrar.identifier)
        XCTAssertEqual(scheduler.submissions.first?.earliestBeginDate, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(refreshedResources, [.playlist])
        guard case .background? = refreshTrigger else {
            return XCTFail("Expected a background refresh trigger")
        }
        XCTAssertEqual(task.completions, [true])
    }

    func testBackgroundProfileLoadFailureKeepsOriginalTypeAndReason() async throws {
        let scheduler = BackgroundSchedulerSpy()
        let failure = NSError(
            domain: "Lifecycle.BackgroundProfileLoad",
            code: -413,
            userInfo: [NSLocalizedDescriptionKey: "后台配置读取原始失败"]
        )
        var reportedStatuses: [String] = []
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { throw failure },
            refresh: { _, _, _ in [] },
            reportStatus: { reportedStatuses.append($0) }
        )
        registrar.register()
        let task = BackgroundTaskSpy()

        try scheduler.launch(task)
        await eventually { task.completions.count == 1 }

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(reportedStatuses.count, 1)
        let message = reportedStatuses.first ?? ""
        XCTAssertTrue(message.contains("NSError"))
        XCTAssertTrue(message.contains("Lifecycle.BackgroundProfileLoad"))
        XCTAssertTrue(message.contains("-413"))
        XCTAssertTrue(message.contains("后台配置读取原始失败"))
    }

    func testBackgroundSchedulingFailureKeepsOriginalTypeAndReason() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        scheduler.submitError = NSError(
            domain: "Lifecycle.BackgroundSchedule",
            code: -414,
            userInfo: [NSLocalizedDescriptionKey: "后台计划提交原始失败"]
        )
        var reportedStatuses: [String] = []
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { [profile] },
            refresh: { _, _, _ in [] },
            now: { now },
            reportStatus: { reportedStatuses.append($0) }
        )

        registrar.scheduleNext()
        await eventually { !reportedStatuses.isEmpty }

        XCTAssertEqual(reportedStatuses.count, 1)
        let message = reportedStatuses.first ?? ""
        XCTAssertTrue(message.contains("NSError"))
        XCTAssertTrue(message.contains("Lifecycle.BackgroundSchedule"))
        XCTAssertTrue(message.contains("-414"))
        XCTAssertTrue(message.contains("后台计划提交原始失败"))
    }

    func testBackgroundExpirationCancelsWorkAndCompletesExactlyOnce() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        let probe = BackgroundWorkProbe(suspendRefresh: true)
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { [profile] },
            refresh: { _, resources, trigger in
                await probe.recordRefresh(resources: resources, trigger: trigger)
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    await probe.recordCancellation()
                }
                return []
            },
            now: { now },
            reportStatus: { _ in }
        )

        registrar.register()
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        await probe.waitUntilRefreshed()
        task.expire()
        let observedCancellation = await probe.waitUntilCancelled()
        XCTAssertTrue(observedCancellation, "Timed out waiting for cancelled background work")
        await eventually { task.completions.count == 1 }
        await Task.yield()

        let cancellationCount = await probe.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(task.completions, [false])
    }

    func testSystemExpirationBeforeMainActorLaunchCompletesFalseWithoutStartingWork() async throws {
        let scheduler = BackgroundSchedulerSpy()
        let loadProbe = BackgroundLoadProbe()
        var completions: [Bool] = []
        let bridge = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { success in
                completions.append(success)
            }
        )
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: {
                await loadProbe.recordLoad()
                return []
            },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )

        registrar.register()
        await Task.detached {
            bridge.systemDidExpire()
            bridge.systemDidExpire()
        }.value
        try scheduler.launch(bridge)
        await eventually { completions.count == 1 }
        for _ in 0..<100 {
            await Task.yield()
        }

        let loadCount = await loadProbe.loadCount
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(completions, [false])
    }

    func testSystemHandoffInstallsExpirationBeforeDispatchAndPreventsWorkAfterEarlyExpiration() async throws {
        let scheduler = BackgroundSchedulerSpy()
        let loadProbe = BackgroundLoadProbe()
        let systemTask = SystemTaskSurfaceSpy()
        let dispatchCapture = MainActorDispatchCapture()
        let handoff = SystemBackgroundRefreshTaskHandoff(
            mainActorDispatch: { action in
                dispatchCapture.capture(
                    action,
                    expirationInstalled: systemTask.hasExpirationHandler
                )
            }
        )
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: {
                await loadProbe.recordLoad()
                return []
            },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )

        registrar.register()
        handoff.handoff(systemTask: systemTask) { task in
            try? scheduler.launch(task)
        }

        XCTAssertTrue(systemTask.hasExpirationHandler)
        XCTAssertEqual(dispatchCapture.expirationInstalledBeforeCapture, true)
        XCTAssertEqual(dispatchCapture.count, 1)
        systemTask.expire()
        systemTask.expire()
        dispatchCapture.runFirst()
        await eventually { systemTask.completions.count == 1 }
        for _ in 0..<100 {
            await Task.yield()
        }

        let loadCount = await loadProbe.loadCount
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(systemTask.completions, [false])
    }

    func testSystemExpirationRacingSuccessCompletesFalseExactlyOnce() async {
        var expirationCount = 0
        var completions: [Bool] = []
        let bridge = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { success in
                completions.append(success)
            }
        )
        bridge.setExpirationHandler {
            expirationCount += 1
        }

        await Task.detached {
            bridge.systemDidExpire()
            bridge.systemDidExpire()
        }.value
        bridge.setTaskCompleted(success: true)
        await eventually { expirationCount == 1 }
        bridge.setTaskCompleted(success: false)

        XCTAssertEqual(expirationCount, 1)
        XCTAssertEqual(completions, [false])
    }

    func testSystemBridgeOrdinarySuccessCompletesOnceAndReleasesOwnership() async throws {
        let scheduler = BackgroundSchedulerSpy()
        var clearCount = 0
        var completions: [Bool] = []
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { [] },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )
        var bridge: SystemBackgroundRefreshTaskBridge? = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {
                clearCount += 1
            },
            completeSystemTask: { success in
                completions.append(success)
            }
        )
        weak let weakBridge = bridge

        registrar.register()
        try scheduler.launch(bridge!)
        await eventually { completions.count == 1 }
        bridge = nil
        await eventually { weakBridge == nil }

        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(completions, [true])
        XCTAssertNil(weakBridge)
    }

    private func waitForLoadCount(_ count: Int, gate: BackgroundProfileLoadGate) async {
        for _ in 0..<1_000 {
            if await gate.loadCount == count { return }
            await Task.yield()
        }
        XCTFail("Expected profile load \(count)")
    }

    private func makeProfile(now: Date) -> SourceProfile {
        SourceProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Test",
            m3uURL: URL(string: "https://example.com/playlist.m3u")!,
            epgURL: URL(string: "https://example.com/epg.xml")!,
            m3uRefreshInterval: .hourly,
            epgRefreshInterval: .manual,
            m3uStatus: ResourceRefreshStatus(),
            epgStatus: ResourceRefreshStatus(),
            createdAt: now,
            updatedAt: now
        )
    }

    private func eventually(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}

private actor ForegroundLoopProbe {
    private(set) var cancellationCount = 0
    private var sleepCount = 0

    func recordSleepStarted() {
        sleepCount += 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func waitForCancellationCount(_ expected: Int) async {
        for _ in 0..<1_000 {
            if cancellationCount >= expected { return }
            await Task.yield()
        }
    }

    func waitForSleepCount(_ expected: Int) async {
        for _ in 0..<1_000 {
            if sleepCount >= expected { return }
            await Task.yield()
        }
    }

    func sleepCountValue() -> Int {
        sleepCount
    }
}

private actor ForegroundLoadFailureGate {
    private var loadCount = 0
    private var firstLoadContinuation: CheckedContinuation<[SourceProfile], any Error>?
    private var firstLoadReturned = false

    func load() async throws -> [SourceProfile] {
        loadCount += 1
        guard loadCount == 1 else { return [] }

        do {
            return try await withCheckedThrowingContinuation { continuation in
                firstLoadContinuation = continuation
            }
        } catch {
            firstLoadReturned = true
            throw error
        }
    }

    func failFirstLoad() {
        firstLoadContinuation?.resume(throwing: LifecycleTestError.loadFailed)
        firstLoadContinuation = nil
    }

    func waitForLoadCount(_ expected: Int) async {
        for _ in 0..<1_000 {
            if loadCount >= expected { return }
            await Task.yield()
        }
    }

    func waitUntilFirstLoadReturned() async {
        for _ in 0..<1_000 {
            if firstLoadReturned { return }
            await Task.yield()
        }
    }
}

private actor BackgroundWorkProbe {
    private(set) var refreshCount = 0
    private(set) var resources: Set<RefreshResource> = []
    private(set) var trigger: RefreshTrigger?
    private(set) var cancellationCount = 0
    private let suspendRefresh: Bool

    init(suspendRefresh: Bool = false) {
        self.suspendRefresh = suspendRefresh
    }

    func recordRefresh(resources: Set<RefreshResource>, trigger: RefreshTrigger) {
        refreshCount += 1
        self.resources = resources
        self.trigger = trigger
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func waitUntilRefreshed() async {
        for _ in 0..<1_000 {
            if trigger != nil { return }
            await Task.yield()
        }
    }

    func waitUntilCancelled() async -> Bool {
        guard suspendRefresh else { return true }
        for _ in 0..<100 {
            if cancellationCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cancellationCount > 0
    }
}

private actor BackgroundLoadProbe {
    private(set) var loadCount = 0

    func recordLoad() {
        loadCount += 1
    }
}

private actor BackgroundProfileLoadGate {
    private let profiles: [[SourceProfile]]
    private let heldLoads: Set<Int>
    private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]
    private(set) var loadCount = 0

    init(profiles: [[SourceProfile]], heldLoads: Set<Int> = []) {
        self.profiles = profiles
        self.heldLoads = heldLoads
    }

    func load() async throws -> [SourceProfile] {
        loadCount += 1
        let index = loadCount
        if heldLoads.contains(index) {
            try await withCheckedThrowingContinuation { continuations[index] = $0 }
        }
        guard profiles.indices.contains(index - 1) else { throw LifecycleTestError.loadFailed }
        return profiles[index - 1]
    }

    func completeLoad(_ index: Int, error: (any Error)? = nil) {
        let continuation = continuations.removeValue(forKey: index)
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

private final class SystemTaskSurfaceSpy: SystemBackgroundRefreshSystemTask, @unchecked Sendable {
    private let lock = NSLock()

    var hasExpirationHandler: Bool {
        withLock { $0.expirationHandler != nil }
    }

    var completions: [Bool] {
        withLock { $0.completionValues }
    }

    func installSystemExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        withLock { $0.expirationHandler = handler }
    }

    @MainActor
    func clearSystemExpirationHandler() {
        withLock { $0.expirationHandler = nil }
    }

    @MainActor
    func completeSystemTask(success: Bool) {
        withLock { $0.completionValues.append(success) }
    }

    func expire() {
        let handler = withLock { $0.expirationHandler }
        handler?()
    }

    private func withLock<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private struct State {
        var expirationHandler: (@Sendable () -> Void)?
        var completionValues: [Bool] = []
    }

    private var state = State()
}

private final class MainActorDispatchCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@MainActor @Sendable () -> Void] = []
    private var recordedExpirationInstalled: Bool?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }

    var expirationInstalledBeforeCapture: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedExpirationInstalled
    }

    func capture(
        _ action: @escaping @MainActor @Sendable () -> Void,
        expirationInstalled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        recordedExpirationInstalled = expirationInstalled
        actions.append(action)
    }

    @MainActor
    func runFirst() {
        let action: (@MainActor @Sendable () -> Void)?
        lock.lock()
        action = actions.isEmpty ? nil : actions.removeFirst()
        lock.unlock()
        action?()
    }
}

@MainActor
private final class BackgroundSchedulerSpy: BackgroundRefreshScheduling {
    struct Submission: Equatable {
        let identifier: String
        let earliestBeginDate: Date
    }

    enum Event: Equatable {
        case cancel
        case begin(Date)
        case succeed(Date)
    }

    private(set) var pendingSubmission: Submission?
    private(set) var events: [Event] = []
    private(set) var registrationCount = 0
    private(set) var cancelledIdentifiers: [String] = []
    private(set) var submissions: [Submission] = []
    var submitError: NSError?
    var holdsAsyncSubmission = false
    var onSubmission: (@MainActor () -> Void)?
    var onSubmissionCompleted: (@MainActor () -> Void)?
    var onMutation: (@MainActor () -> Void)?
    private(set) var asyncSubmissionCount = 0
    private(set) var inFlightSubmissions = 0
    private(set) var maximumInFlightSubmissions = 0
    private var submissionContinuation: CheckedContinuation<Void, any Error>?

    func completeAsyncSubmission(error: (any Error)? = nil) {
        let continuation = submissionContinuation
        submissionContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    func submit(identifier: String, earliestBeginDate: Date) async throws {
        asyncSubmissionCount += 1
        events.append(.begin(earliestBeginDate))
        inFlightSubmissions += 1
        maximumInFlightSubmissions = max(maximumInFlightSubmissions, inFlightSubmissions)
        onSubmission?()
        onMutation?()
        defer { inFlightSubmissions -= 1 }
        if holdsAsyncSubmission {
            try await withCheckedThrowingContinuation { submissionContinuation = $0 }
        }
        if let submitError { throw submitError }
        let submission = Submission(identifier: identifier, earliestBeginDate: earliestBeginDate)
        submissions.append(submission)
        pendingSubmission = submission
        events.append(.succeed(earliestBeginDate))
        onSubmissionCompleted?()
    }
    private var handler: (@MainActor @Sendable (any BackgroundRefreshTask) -> Void)?

    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool {
        registrationCount += 1
        self.handler = handler
        return true
    }

    func cancel(identifier: String) {
        onMutation?()
        cancelledIdentifiers.append(identifier)
        pendingSubmission = nil
        events.append(.cancel)
    }

    func launch(_ task: any BackgroundRefreshTask) throws {
        guard let handler else { throw LifecycleTestError.notRegistered }
        handler(task)
    }
}

@MainActor
private final class BackgroundTaskSpy: BackgroundRefreshTask {
    private var expirationHandler: (@MainActor @Sendable () -> Void)?
    private(set) var completions: [Bool] = []

    func setExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        expirationHandler = handler
    }

    func clearExpirationHandler() {
        expirationHandler = nil
    }

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }

    func expire() {
        expirationHandler?()
    }
}

private enum LifecycleTestError: Error {
    case notRegistered
    case loadFailed
}
