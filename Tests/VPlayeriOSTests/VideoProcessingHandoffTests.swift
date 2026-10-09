// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreVideo
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
    func testSecondBackgroundTransitionStillJoinsUnfinishedEarlierGPUWork() throws {
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        var unfinished: GPUVideoWorkTicket?
        XCTAssertNil(try gate.withGPUAdmission { unfinished = $0 })
        gate.setForeground(false)
        gate.setForeground(true)
        gate.setForeground(false)
        let fence = try XCTUnwrap(try gate.withGPUAdmission { _ in XCTFail() })
        XCTAssertFalse(fence.wait(timeout: .now()))
        unfinished?.finish()
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

@MainActor
final class IOSPlayerTransportAuthorityTests: XCTestCase {
    func testProductionDriverUsesTheControlledPlayerBoundary() throws {
        let driver = try SystemAVPlayerDriver.make()
        XCTAssertTrue(driver.player is IOSControlledAVPlayer)
    }
    func testPublicPiPTransportEntryPointsDoNotMutateBeforeAuthority() async {
        let player = IOSControlledAVPlayer()
        var requests: [Bool] = []
        player.setTransportIntentHandler { requests.append($0) }
        player.play()
        XCTAssertEqual(player.rate, 0)
        await flushMainDelivery()
        XCTAssertEqual(requests, [false])
        player.pause()
        await flushMainDelivery()
        XCTAssertEqual(requests, [false, true])
        player.rate = 1
        XCTAssertEqual(player.rate, 0)
        await flushMainDelivery()
        player.playImmediately(atRate: 1)
        XCTAssertEqual(player.rate, 0)
        await flushMainDelivery()
        player.setRate(1, time: .invalid, atHostTime: .invalid)
        XCTAssertEqual(player.rate, 0)
        await flushMainDelivery()
        XCTAssertEqual(requests, [false, true, false, false, false])
        player.performDriverMutation { player.pause() }
        await flushMainDelivery()
        XCTAssertEqual(requests.count, 5, "Authorized driver mutations cannot loop into UI intents")
    }
    private func flushMainDelivery() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    func testBurstControlsCoalesceAndLateLayerDetachPreservesNewOwner() async {
        let player = IOSControlledAVPlayer()
        let context = AVPlayerPresentationContext(player: player)
        let oldLayer = AVPlayerLayer()
        let currentLayer = AVPlayerLayer()
        context.attach(to: oldLayer)
        var oldRequests = 0
        XCTAssertTrue(context.setPictureInPictureTransportHandler({ _ in oldRequests += 1 }, for: oldLayer))
        player.pause()
        context.attach(to: currentLayer)
        var latest: [Bool] = []
        XCTAssertTrue(context.setPictureInPictureTransportHandler({ latest.append($0) }, for: currentLayer))
        XCTAssertFalse(context.setPictureInPictureTransportHandler(nil, for: oldLayer))
        context.detach(from: oldLayer)
        player.play()
        player.pause()
        player.play()
        await flushMainDelivery()
        XCTAssertEqual(latest, [false])
        XCTAssertEqual(oldRequests, 0)
        XCTAssertTrue(currentLayer.player === player)
        XCTAssertNil(oldLayer.player)
        context.detach(from: currentLayer)
    }
    func testRetiringTransportOwnerDiscardsQueuedIntents() async {
        let player = IOSControlledAVPlayer()
        var old = 0
        player.setTransportIntentHandler { _ in old += 1 }
        player.play()
        player.setTransportIntentHandler(nil)
        await flushMainDelivery()
        XCTAssertEqual(old, 0)
        XCTAssertEqual(player.rate, 0)
    }
}

private final class HandoffEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}

final class GPUSubmissionReturnTests: XCTestCase {
    func testEarlyCompletionWaitsForSubmissionReturnAndIsDeliveredOnce() {
        let events = HandoffEvents()
        let latch = GPUSubmissionReturn<Int> { value in events.append("complete:\(value)") }
        latch.receive(1)
        latch.receive(99)
        XCTAssertEqual(events.snapshot, [])
        events.append("resources-released")
        latch.submissionReturned()
        latch.receive(2)
        latch.submissionReturned()
        XCTAssertEqual(events.snapshot, ["resources-released", "complete:1"])
    }
    func testDelayedGPUCompletionPublishesBeforeWaitingCPUSuccessor() throws {
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        var admitted: GPUVideoWorkTicket?
        XCTAssertNil(try gate.withGPUAdmission { admitted = $0 })
        let ticket = try XCTUnwrap(admitted)
        gate.setForeground(false)
        let fence = try XCTUnwrap(try gate.withGPUAdmission { _ in XCTFail() })
        let events = HandoffEvents()
        let finished = expectation(description: "CPU joins prior GPU publication")
        let latch = GPUSubmissionReturn<Int> { _ in
            events.append("GPU")
            ticket.finish()
        }
        latch.submissionReturned()
        DispatchQueue.global().async {
            XCTAssertTrue(fence.wait(timeout: .now() + .seconds(2)))
            events.append("CPU")
            finished.fulfill()
        }
        latch.receive(1)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(events.snapshot, ["GPU", "CPU"])
    }
}

private final class HandoffGPURecorder: YADIFCommandSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [UInt64: @Sendable (YADIFCommandCompletion) -> Void] = [:]
    private let submitted: @Sendable (UInt64) -> Void

    init(submitted: @escaping @Sendable (UInt64) -> Void) { self.submitted = submitted }

    func submit(job: YADIFJob, outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
                completion: @escaping @Sendable (YADIFCommandCompletion) -> Void) throws(YADIFFailure) {
        lock.withLock { callbacks[job.current.frame.accessUnitID] = completion }
        submitted(job.current.frame.accessUnitID)
    }

    func complete(_ id: UInt64, callbackCount: Int = 1) throws {
        let callback = try XCTUnwrap(lock.withLock { callbacks.removeValue(forKey: id) })
        for _ in 0..<callbackCount { callback(.init(result: .completed)) }
    }
}

private final class HandoffDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AdaptiveYADIFHandoffEvent] = []
    func append(_ event: AdaptiveYADIFHandoffEvent) { lock.withLock { events.append(event) } }
    var snapshot: [AdaptiveYADIFHandoffEvent] { lock.withLock { events } }
}

private struct HandoffYADIFWork {
    let job: YADIFJob
    let outputs: (first: CVPixelBuffer, second: CVPixelBuffer)

    init(id: UInt64) throws {
        let input = try VideoTestFactories.nv12(width: 8, height: 8)
        outputs = (try VideoTestFactories.nv12(width: 8, height: 8),
                   try VideoTestFactories.nv12(width: 8, height: 8))
        try Self.fill(input, with: 73)
        try Self.fill(outputs.first, with: 165)
        try Self.fill(outputs.second, with: 165)
        let pts = CMTime(value: Int64(id), timescale: 25)
        let duration = CMTime(value: 1, timescale: 25)
        let frame = VideoTestFactories.decodedFrame(id: id, pixelBuffer: input,
            presentationTimeStamp: pts, duration: duration, generation: .init(rawValue: 1),
            parserMetadata: .init(fieldOrder: .tt, pictureStructure: .frame, isInterlaced: true,
                repeatFirstField: false, topFieldFirst: true, sourcePTS90k: nil))
        let normalized = NormalizedDecodedFrame(frame: frame, presentationTimeStamp: pts,
            frameDuration: duration, fieldDuration: CMTime(value: 1, timescale: 50),
            timingWasSynthesized: false, provenance: .trustedPresentationCadence)
        job = YADIFJob(previous: normalized, current: normalized, next: normalized,
            order: .init(coded: .tt), spatialOnly: false)
    }

    private static func fill(_ buffer: CVPixelBuffer, with value: UInt8) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }

    func assertOutput(_ value: UInt8, file: StaticString = #filePath, line: UInt = #line) throws {
        for buffer in [outputs.first, outputs.second] {
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess,
                           file: file, line: line)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                    .assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let bytesPerRow = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
                for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: base + row * stride, count: bytesPerRow)),
                        Array(repeating: value, count: bytesPerRow), file: file, line: line)
                }
            }
        }
    }
}

final class AdaptiveYADIFHandoffTests: XCTestCase {
    func testDelayedGPUThenCPUThenForegroundGPUPreservesCompletionOrderAndPixels() throws {
        let firstGPU = expectation(description: "first GPU submission")
        let cpuWaiting = expectation(description: "CPU selected and joining GPU fence")
        let finalGPU = expectation(description: "foreground GPU submission")
        let completed = expectation(description: "all three jobs complete once")
        completed.expectedFulfillmentCount = 3
        completed.assertForOverFulfill = true
        let events = HandoffEvents()
        let diagnostics = HandoffDiagnostics()
        let gpu = HandoffGPURecorder { id in
            events.append("gpu:\(id)")
            if id == 1 { firstGPU.fulfill() }
            else if id == 3 { finalGPU.fulfill() }
            else { XCTFail("Background work must use the CPU kernel") }
        }
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        let submitter = AdaptiveYADIFCommandSubmitter(gpu: gpu, gate: gate) { event in
            diagnostics.append(event)
            if case .fenceWaitBegan(id: 2) = event { cpuWaiting.fulfill() }
        }
        let first = try HandoffYADIFWork(id: 1)
        let cpu = try HandoffYADIFWork(id: 2)
        let last = try HandoffYADIFWork(id: 3)
        func submit(_ work: HandoffYADIFWork) throws {
            let id = work.job.current.frame.accessUnitID
            try submitter.submit(job: work.job, outputs: work.outputs) { result in
                XCTAssertEqual(result.result, .completed)
                events.append("complete:\(id)")
                completed.fulfill()
            }
        }
        try submit(first)
        wait(for: [firstGPU], timeout: 2)
        gate.setPictureInPicture(true)
        gate.setForeground(false)
        try submit(cpu)
        wait(for: [cpuWaiting], timeout: 2)
        XCTAssertEqual(events.snapshot, ["gpu:1"])

        // Select the final job only after the middle job selected CPU. The lane
        // must finish that CPU job before admitting the foreground successor.
        gate.setForeground(true)
        gate.setPictureInPicture(false)
        try submit(last)
        try gpu.complete(1, callbackCount: 2)
        wait(for: [finalGPU], timeout: 2)
        XCTAssertEqual(events.snapshot, ["gpu:1", "complete:1", "complete:2", "gpu:3"])
        try cpu.assertOutput(73)
        try last.assertOutput(165)
        try gpu.complete(3, callbackCount: 2)
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(events.snapshot, ["gpu:1", "complete:1", "complete:2", "gpu:3", "complete:3"])
        XCTAssertEqual(diagnostics.snapshot.compactMap { event -> UInt64? in
            if case let .completed(id, _, _, _) = event { return id }
            return nil
        }, [1, 2, 3])
        let cpuTimes = diagnostics.snapshot.compactMap { event -> Double? in
            if case let .completed(id: 2, mode: .cpu, result: .completed, cpuProcessingMilliseconds: elapsed) = event {
                return elapsed
            }
            return nil
        }
        XCTAssertEqual(cpuTimes.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(cpuTimes.first), 0)
    }

    func testCancellationDuringGPUFenceRetiresEachJobOnceAndRestoresAllThreeSlots() throws {
        let firstGPU = expectation(description: "delayed GPU submission")
        let cpuWaiting = expectation(description: "CPU fence entered")
        let cancelled = expectation(description: "old generation completions")
        cancelled.expectedFulfillmentCount = 3
        cancelled.assertForOverFulfill = true
        let replacementGPU = expectation(description: "all replacement slots admitted")
        replacementGPU.expectedFulfillmentCount = 3
        let replacementCompleted = expectation(description: "all replacement slots retired")
        replacementCompleted.expectedFulfillmentCount = 3
        replacementCompleted.assertForOverFulfill = true
        let lastGPU = expectation(description: "capacity remains reusable")
        let lastCompleted = expectation(description: "final retirement")
        lastCompleted.assertForOverFulfill = true
        let diagnostics = HandoffDiagnostics()
        let gpu = HandoffGPURecorder { id in
            switch id {
            case 1: firstGPU.fulfill()
            case 4...6: replacementGPU.fulfill()
            case 7: lastGPU.fulfill()
            default: XCTFail("Cancelled work must never reach GPU")
            }
        }
        let gate = GPUVideoProcessingGate()
        gate.setForeground(true)
        let submitter = AdaptiveYADIFCommandSubmitter(gpu: gpu, gate: gate) { event in
            diagnostics.append(event)
            if case .fenceWaitBegan(id: 2) = event { cpuWaiting.fulfill() }
        }
        let first = try HandoffYADIFWork(id: 1)
        let waiting = try HandoffYADIFWork(id: 2)
        let queued = try HandoffYADIFWork(id: 3)
        try submitter.submit(job: first.job, outputs: first.outputs) { result in
            XCTAssertEqual(result.result, .completed)
            cancelled.fulfill()
        }
        wait(for: [firstGPU], timeout: 2)
        gate.setForeground(false)
        try submitter.submit(job: waiting.job, outputs: waiting.outputs) { result in
            XCTAssertEqual(result.result, .failed)
            cancelled.fulfill()
        }
        wait(for: [cpuWaiting], timeout: 2)
        try submitter.submit(job: queued.job, outputs: queued.outputs) { result in
            XCTAssertEqual(result.result, .failed)
            cancelled.fulfill()
        }
        submitter.cancelPendingWork()
        submitter.cancelPendingWork()
        try gpu.complete(1, callbackCount: 2)
        wait(for: [cancelled], timeout: 2)
        try waiting.assertOutput(165)
        try queued.assertOutput(165)

        gate.setForeground(true)
        let replacements = try (4...6).map { try HandoffYADIFWork(id: UInt64($0)) }
        for work in replacements {
            try submitter.submit(job: work.job, outputs: work.outputs) { result in
                XCTAssertEqual(result.result, .completed)
                replacementCompleted.fulfill()
            }
        }
        wait(for: [replacementGPU], timeout: 2)
        let last = try HandoffYADIFWork(id: 7)
        XCTAssertThrowsError(try submitter.submit(job: last.job, outputs: last.outputs) { _ in
            XCTFail("A rejected submission cannot complete")
        }) { error in
            XCTAssertEqual(error as? YADIFFailure, .commandBufferAllocationFailed)
        }
        for id in UInt64(4)...6 { try gpu.complete(id, callbackCount: 2) }
        wait(for: [replacementCompleted], timeout: 2)
        try submitter.submit(job: last.job, outputs: last.outputs) { result in
            XCTAssertEqual(result.result, .completed)
            lastCompleted.fulfill()
        }
        wait(for: [lastGPU], timeout: 2)
        try gpu.complete(7, callbackCount: 2)
        wait(for: [lastCompleted], timeout: 2)
        let completedIDs = diagnostics.snapshot.compactMap { event -> UInt64? in
            if case let .completed(id, _, _, _) = event { return id }
            return nil
        }
        XCTAssertEqual(completedIDs.sorted(), Array(UInt64(1)...7))
        XCTAssertFalse(diagnostics.snapshot.contains { event in
            if case .modeSelected(id: 3, mode: _) = event { return true }
            return false
        }, "Queued work cancelled before admission never selects an execution mode")
    }
}

private final class HandoffLogRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [AdaptiveYADIFLogRecord] = []
    func append(_ record: AdaptiveYADIFLogRecord) { lock.withLock { records.append(record) } }
    var snapshot: [AdaptiveYADIFLogRecord] { lock.withLock { records } }
    var windows: [AdaptiveYADIFLogWindow] {
        snapshot.compactMap { if case let .cpuWindow(window) = $0 { return window }; return nil }
    }
    var modes: [AdaptiveVideoProcessingMode] {
        snapshot.compactMap { if case let .modeChanged(mode) = $0 { return mode }; return nil }
    }
}

final class AdaptiveYADIFDiagnosticsTests: XCTestCase {
    func testOneSecondWindowAndModeChangeFlushHaveExactCountsAndWallTimes() throws {
        let records = HandoffLogRecords()
        let diagnostics = AdaptiveYADIFDiagnostics { records.append($0) }
        diagnostics.select(.cpu, at: 10)
        let phases = CPUYADIFProcessingTimings(validationMilliseconds: 1,
            inputLockMilliseconds: 2, outputLockMilliseconds: 3,
            parallelMilliseconds: 20, unlockMilliseconds: 4)
        diagnostics.completeCPU(success: true, queue: 1, fence: 2, processing: 30, total: 35,
            phases: phases, at: 10.5)
        XCTAssertTrue(records.windows.isEmpty)
        diagnostics.completeCPU(success: false, queue: 4, fence: 5, processing: nil, total: 9,
            phases: nil, at: 11)
        let first = try XCTUnwrap(records.windows.first)
        XCTAssertEqual(first.seconds, 1)
        XCTAssertEqual(first.successfulPairs, 1)
        XCTAssertEqual(first.failedPairs, 1)
        XCTAssertEqual(first.queue.totalMilliseconds, 5)
        XCTAssertEqual(first.queue.maximumMilliseconds, 4)
        XCTAssertEqual(first.fence.totalMilliseconds, 7)
        XCTAssertEqual(first.fence.maximumMilliseconds, 5)
        XCTAssertEqual(first.processing.totalMilliseconds, 30)
        XCTAssertEqual(first.processing.maximumMilliseconds, 30)
        XCTAssertEqual(first.total.totalMilliseconds, 44)
        XCTAssertEqual(first.total.maximumMilliseconds, 35)
        XCTAssertEqual(first.validation.totalMilliseconds, 1)
        XCTAssertEqual(first.inputLock.totalMilliseconds, 2)
        XCTAssertEqual(first.outputLock.totalMilliseconds, 3)
        XCTAssertEqual(first.parallel.totalMilliseconds, 20)
        XCTAssertEqual(first.unlock.totalMilliseconds, 4)

        diagnostics.select(.cpu, at: 11.25)
        diagnostics.completeCPU(success: true, queue: 0, fence: 0, processing: 40, total: 40,
            phases: nil, at: 11.5)
        XCTAssertEqual(records.windows.count, 1)
        diagnostics.select(.gpu, at: 11.75)
        let tail = try XCTUnwrap(records.windows.last)
        XCTAssertEqual(records.windows.count, 2)
        XCTAssertEqual(tail.seconds, 0.75)
        XCTAssertEqual(tail.successfulPairs, 1)
        XCTAssertEqual(tail.failedPairs, 0)
        XCTAssertEqual(tail.processing.totalMilliseconds, 40)
        XCTAssertEqual(records.modes, [.cpu, .gpu])
        diagnostics.select(.gpu, at: 12)
        diagnostics.flush(at: 13)
        XCTAssertEqual(records.snapshot.count, 4, "Repeated mode/empty flush cannot produce log spam")
    }

    func testManyCompletionsCollapseIntoOneWindowAndExplicitFlushResetsIt() throws {
        let records = HandoffLogRecords()
        let diagnostics = AdaptiveYADIFDiagnostics { records.append($0) }
        diagnostics.select(.cpu, at: 0)
        for _ in 0..<10_000 {
            diagnostics.completeCPU(success: true, queue: 2, fence: 3, processing: 4, total: 10,
                phases: nil, at: 0.5)
        }
        XCTAssertEqual(records.snapshot.count, 1, "A burst must not queue one log record per frame")
        diagnostics.flush(at: 0.5)
        let window = try XCTUnwrap(records.windows.first)
        XCTAssertEqual(window.seconds, 0.5)
        XCTAssertEqual(window.successfulPairs, 10_000)
        XCTAssertEqual(window.failedPairs, 0)
        XCTAssertEqual(window.queue.totalMilliseconds, 20_000)
        XCTAssertEqual(window.fence.totalMilliseconds, 30_000)
        XCTAssertEqual(window.processing.totalMilliseconds, 40_000)
        XCTAssertEqual(window.total.totalMilliseconds, 100_000)
        diagnostics.flush(at: 0.75)
        XCTAssertEqual(records.windows.count, 1)
        diagnostics.completeCPU(success: true, queue: 1, fence: 0, processing: 8, total: 9,
            phases: nil, at: 1)
        diagnostics.flush(at: 1)
        XCTAssertEqual(records.windows.count, 2)
        XCTAssertEqual(records.windows.last?.successfulPairs, 1)
        XCTAssertEqual(records.windows.last?.processing.totalMilliseconds, 8)
    }

    func testCPUPhaseCallbackRunsOnceWithSeparateNonnegativeWallTimes() throws {
        let work = try HandoffYADIFWork(id: 1)
        var callbackCount = 0
        var observed: CPUYADIFProcessingTimings?
        let started = ProcessInfo.processInfo.systemUptime
        try CPUVideoProcessing.yadif(job: work.job, outputs: work.outputs) { timings in
            callbackCount += 1
            observed = timings
            XCTAssertNoThrow(try work.assertOutput(73))
        }
        let total = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let timings = try XCTUnwrap(observed)
        XCTAssertEqual(callbackCount, 1)
        let components = [timings.validationMilliseconds, timings.inputLockMilliseconds,
            timings.outputLockMilliseconds, timings.parallelMilliseconds, timings.unlockMilliseconds]
        XCTAssertTrue(components.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertGreaterThan(timings.parallelMilliseconds, 0)
        XCTAssertLessThanOrEqual(components.reduce(0, +), total)

        callbackCount = 0
        observed = nil
        XCTAssertThrowsError(try CPUVideoProcessing.yadif(job: work.job,
            outputs: (work.outputs.first, work.outputs.first)) { timings in
                callbackCount += 1
                observed = timings
            }) { error in
                XCTAssertEqual(error as? YADIFFailure, .invalidPlaneLayout)
            }
        let rejected = try XCTUnwrap(observed)
        XCTAssertEqual(callbackCount, 1, "Validation failure still reports one completed timing observation")
        XCTAssertGreaterThanOrEqual(rejected.validationMilliseconds, 0)
        XCTAssertEqual(rejected.inputLockMilliseconds, 0)
        XCTAssertEqual(rejected.outputLockMilliseconds, 0)
        XCTAssertEqual(rejected.parallelMilliseconds, 0)
    }
}
