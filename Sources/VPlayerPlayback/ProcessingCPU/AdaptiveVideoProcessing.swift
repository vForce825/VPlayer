// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#if os(iOS)
import CoreVideo
import Foundation
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
import OSLog
#endif

private final class CPUWorkLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var pending = 0
    private var revision = UUID()
    init(maximum: Int) { self.maximum = maximum }
    func admit() -> UUID? {
        lock.withLock {
            guard pending < maximum else { return nil }
            pending += 1
            return revision
        }
    }
    func isCurrent(_ value: UUID) -> Bool { lock.withLock { revision == value } }
    func cancel() { lock.withLock { revision = UUID() } }
    func retire() { lock.withLock { precondition(pending > 0); pending -= 1 } }
}

private final class CPUOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Value) -> Void)?
    init(_ callback: @escaping @Sendable (Value) -> Void) { self.callback = callback }
    func call(_ value: Value) {
        let deliver = lock.withLock {
            let current = callback
            callback = nil
            return current
        }
        deliver?(value)
    }
}

/// Handles even a synchronous mock/native callback without blocking it. GPU
/// completion is exposed only after submit has returned and released its input
/// temporaries; it must precede ticket completion so a waiting CPU successor
/// cannot publish newer PTS first.
final class GPUSubmissionReturn<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var returned = false
    private var received = false
    private var pending: Value?
    private var callback: (@Sendable (Value) -> Void)?
    init(_ callback: @escaping @Sendable (Value) -> Void) { self.callback = callback }
    func receive(_ value: Value) {
        let deliver = lock.withLock { () -> (@Sendable (Value) -> Void)? in
            guard !received else { return nil }
            received = true
            guard returned else { pending = value; return nil }
            defer { callback = nil }
            return callback
        }
        deliver?(value)
    }
    func submissionReturned() {
        let delivery = lock.withLock { () -> (Value, @Sendable (Value) -> Void)? in
            returned = true
            guard let pending, let callback else { return nil }
            self.pending = nil; self.callback = nil
            return (pending, callback)
        }
        if let delivery { delivery.1(delivery.0) }
    }
}

/// Confined to the serial handoff lane after enqueue. Clearing the only work
/// slot releases physical surfaces before completion exposes capacity/drain.
private final class CPUWorkSlot<Value: Sendable>: @unchecked Sendable {
    var value: Value?
    init(_ value: Value) { self.value = value }
    func clear() { value = nil }
}

private struct CPUYADIFWork: @unchecked Sendable {
    let job: YADIFJob
    let outputs: (first: CVPixelBuffer, second: CVPixelBuffer)
}

enum AdaptiveVideoProcessingMode: Sendable, Equatable {
    case gpu
    case cpu
}

/// Delivered inline on the handoff/GPU completion lanes, outside internal
/// locks. Observers must be thread-safe, fast and nonblocking: never wait for
/// this submitter's lane or GPU fence. This seam owns no queue or retained media.
/// A nil mode means cancellation before choosing an execution backend.
/// CPU elapsed time is nil when performance diagnostics are compiled out.
enum AdaptiveYADIFHandoffEvent: Sendable {
    case modeSelected(id: UInt64, mode: AdaptiveVideoProcessingMode)
    case fenceWaitBegan(id: UInt64)
    case completed(id: UInt64, mode: AdaptiveVideoProcessingMode?,
                   result: YADIFCommandResult, cpuProcessingMilliseconds: Double?)
}

private struct AdaptiveYADIFCompletion: Sendable {
    var completion: YADIFCommandCompletion
    let mode: AdaptiveVideoProcessingMode?
    var cpuProcessingMilliseconds: Double? = nil
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
    var queueMilliseconds: Double = 0
    var fenceMilliseconds: Double = 0
    var phases: CPUYADIFProcessingTimings? = nil
#endif
}

#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
struct AdaptiveYADIFDurations: Sendable {
    var totalMilliseconds: Double = 0
    var maximumMilliseconds: Double = 0
    mutating func record(_ milliseconds: Double) {
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
    }
}

struct CPUYADIFWorkerWindow: Sendable {
    var pairs: UInt64 = 0
    var expectedWorkers: UInt64 = 0
    var cpu = CPUYADIFMeasuredDurations()
    var wall = CPUYADIFMeasuredDurations()
    var startDelay = CPUYADIFMeasuredDurations()
    var startSpread = CPUYADIFMeasuredDurations()
    var joinTail = CPUYADIFMeasuredDurations()
    var requestedQoSStart = CPUYADIFRequestedQoSCounts()
    var requestedQoSEnd = CPUYADIFRequestedQoSCounts()

    var cpuClockStatus: String {
        guard cpu.count > 0 else { return "unverified" }
        return cpu.count == expectedWorkers ? "verified" : "partial"
    }

    mutating func record(_ summary: CPUYADIFWorkerSummary) {
        pairs += 1
        expectedWorkers += summary.expectedWorkers
        cpu.merge(summary.cpu)
        wall.merge(summary.wall)
        startDelay.merge(summary.startDelay)
        if let value = summary.startSpreadMilliseconds { startSpread.record(value) }
        if let value = summary.joinTailMilliseconds { joinTail.record(value) }
        requestedQoSStart.merge(summary.requestedQoSStart)
        requestedQoSEnd.merge(summary.requestedQoSEnd)
    }
}

struct AdaptiveYADIFLogWindow: Sendable {
    var seconds: Double = 0
    var successfulPairs: UInt64 = 0
    var failedPairs: UInt64 = 0
    var queue = AdaptiveYADIFDurations()
    var fence = AdaptiveYADIFDurations()
    var processing = AdaptiveYADIFDurations()
    var total = AdaptiveYADIFDurations()
    var validation = AdaptiveYADIFDurations()
    var inputLock = AdaptiveYADIFDurations()
    var outputLock = AdaptiveYADIFDurations()
    var parallel = AdaptiveYADIFDurations()
    var unlock = AdaptiveYADIFDurations()
    var workers = CPUYADIFWorkerWindow()
    // Last observed surface context; transitions are counted so mixed windows
    // cannot be mistaken for a measurement of one format/worker configuration.
    var context: CPUYADIFProcessingContext?
    var contextChanges: UInt64 = 0
    var thermalAtLog = "unknown"
    var lowPowerAtLog = false
    var hasCompletions: Bool { successfulPairs != 0 || failedPairs != 0 }
}

enum AdaptiveYADIFLogRecord: Sendable {
    case modeChanged(AdaptiveVideoProcessingMode)
    case cpuWindow(AdaptiveYADIFLogWindow)
}

/// One fixed-size accumulator per submitter. No per-frame history, media,
/// timers or logging queue. The sink runs outside the state lock.
final class AdaptiveYADIFDiagnostics: @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.vplayer.playback", category: "VideoHandoff")
    private let lock = NSLock()
    private let sink: @Sendable (AdaptiveYADIFLogRecord) -> Void
    private var mode: AdaptiveVideoProcessingMode?
    private var windowStartedAt: TimeInterval?
    private var window = AdaptiveYADIFLogWindow()

    init(sink: (@Sendable (AdaptiveYADIFLogRecord) -> Void)? = nil) {
        let identifier = String(UUID().uuidString.prefix(8))
        self.sink = sink ?? { record in
            let message: String
            switch record {
            case let .modeChanged(mode):
                message = "IOS_VIDEO_HANDOFF id=\(identifier) mode=\(mode)"
            case let .cpuWindow(window):
                func number(_ value: Double) -> String { String(format: "%.3f", value) }
                func times(_ value: AdaptiveYADIFDurations) -> String {
                    "\(number(value.totalMilliseconds))/\(number(value.maximumMilliseconds))"
                }
                func workerTimes(_ value: CPUYADIFMeasuredDurations) -> String {
                    guard let minimum = value.minimumMilliseconds else { return "unverified" }
                    return "\(number(value.totalMilliseconds))/\(number(minimum))/\(number(value.maximumMilliseconds))"
                }
                let context: String
                if let observed = window.context {
                    context = "surface=\(observed.width)x\(observed.height) "
                        + "pixel_format=\(String(format: "%08x", observed.pixelFormat)) depth=\(observed.depth) "
                        + "workers=\(observed.workers) active_processors=\(observed.activeProcessors)"
                } else {
                    context = "surface=unverified pixel_format=unverified depth=unverified workers=unverified active_processors=unverified"
                }
                message = "IOS_VIDEO_CPU id=\(identifier) mode=cpu seconds=\(number(window.seconds)) "
                    + "pairs_ok=\(window.successfulPairs) pairs_failed=\(window.failedPairs) "
                    + "pair_budget_ms_25i=40 timings_ms=sum/max "
                    + "queue=\(times(window.queue)) fence=\(times(window.fence)) "
                    + "processing=\(times(window.processing)) total=\(times(window.total)) "
                    + "validation=\(times(window.validation)) input_lock=\(times(window.inputLock)) "
                    + "output_lock=\(times(window.outputLock)) parallel_wall=\(times(window.parallel)) "
                    + "unlock=\(times(window.unlock)) "
                    + "worker_pairs=\(window.workers.pairs) worker_samples=\(window.workers.wall.count)/\(window.workers.expectedWorkers) "
                    + "worker_cpu_clock=\(window.workers.cpuClockStatus) worker_cpu_valid=\(window.workers.cpu.count) "
                    + "worker_times_ms=sum/min/max worker_cpu_ms=\(workerTimes(window.workers.cpu)) "
                    + "worker_wall_ms=\(workerTimes(window.workers.wall)) worker_start_delay=\(workerTimes(window.workers.startDelay)) "
                    + "worker_start_spread=\(workerTimes(window.workers.startSpread)) worker_join_tail=\(workerTimes(window.workers.joinTail)) "
                    + "worker_join_valid=\(window.workers.joinTail.count) "
                    + "requested_qos_order=interactive/initiated/default/utility/background/unspecified/unknown "
                    + "requested_qos_start=\(window.workers.requestedQoSStart.logValue) requested_qos_end=\(window.workers.requestedQoSEnd.logValue) "
                    + "\(context) context_changes=\(window.contextChanges) thermal_at_log=\(window.thermalAtLog) low_power_at_log=\(window.lowPowerAtLog ? 1 : 0)"
            }
            Self.logger.notice("\(message, privacy: .public)")
        }
    }

    func select(_ selected: AdaptiveVideoProcessingMode, at now: TimeInterval) {
        let change = lock.withLock { () -> (Bool, AdaptiveYADIFLogWindow?) in
            guard selected != mode else { return (false, nil) }
            let pending = takeWindowLocked(at: now)
            mode = selected
            windowStartedAt = selected == .cpu ? now : nil
            return (true, pending)
        }
        if let pending = change.1 { sink(.cpuWindow(pending)) }
        if change.0 { sink(.modeChanged(selected)) }
    }

    func completeCPU(success: Bool, queue: Double, fence: Double, processing: Double?, total: Double,
                     phases: CPUYADIFProcessingTimings?, at now: TimeInterval) {
        let completed = lock.withLock { () -> AdaptiveYADIFLogWindow? in
            if windowStartedAt == nil { windowStartedAt = now }
            if success { window.successfulPairs &+= 1 } else { window.failedPairs &+= 1 }
            window.queue.record(queue)
            window.fence.record(fence)
            if let processing { window.processing.record(processing) }
            window.total.record(total)
            if let phases {
                window.validation.record(phases.validationMilliseconds)
                window.inputLock.record(phases.inputLockMilliseconds)
                window.outputLock.record(phases.outputLockMilliseconds)
                window.parallel.record(phases.parallelMilliseconds)
                window.unlock.record(phases.unlockMilliseconds)
                if let workers = phases.workers { window.workers.record(workers) }
                if let context = phases.context {
                    if let previous = window.context, previous != context { window.contextChanges += 1 }
                    window.context = context
                }
            }
            guard now - (windowStartedAt ?? now) >= 1 else { return nil }
            return takeWindowLocked(at: now)
        }
        if let completed { sink(.cpuWindow(completed)) }
    }

    func flush(at now: TimeInterval) {
        let pending = lock.withLock { takeWindowLocked(at: now) }
        if let pending { sink(.cpuWindow(pending)) }
    }

    private func takeWindowLocked(at now: TimeInterval) -> AdaptiveYADIFLogWindow? {
        guard window.hasCompletions else { return nil }
        window.seconds = max(0, now - (windowStartedAt ?? now))
        // Device state is sampled only when emitting a bounded window, not per
        // worker or pixel. It is context at emission, not a history of the run.
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: window.thermalAtLog = "nominal"
        case .fair: window.thermalAtLog = "fair"
        case .serious: window.thermalAtLog = "serious"
        case .critical: window.thermalAtLog = "critical"
        @unknown default: window.thermalAtLog = "unknown"
        }
        window.lowPowerAtLog = ProcessInfo.processInfo.isLowPowerModeEnabled
        let snapshot = window
        window = AdaptiveYADIFLogWindow()
        windowStartedAt = now
        return snapshot
    }
}
#endif

/// A serial handoff lane does not replace the YADIF scheduler/window. It orders
/// admission to its existing GPU submitter or the identical CPU kernel. CPU
/// execution joins real prior GPU completion, and finishes before a later GPU
/// submission can leave this lane. The scheduler still bounds admitted jobs.
final class AdaptiveYADIFCommandSubmitter: YADIFCommandSubmitting, @unchecked Sendable {
    private let gpu: any YADIFCommandSubmitting
    private let gate: GPUVideoProcessingGate
    private let lane = DispatchQueue(label: "com.vplayer.yadif-handoff", qos: .userInitiated)
    private let limiter = CPUWorkLimiter(maximum: 3)
    private let observer: (@Sendable (AdaptiveYADIFHandoffEvent) -> Void)?
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
    private let diagnostics = AdaptiveYADIFDiagnostics()
#endif
    init(gpu: any YADIFCommandSubmitting, gate: GPUVideoProcessingGate = .shared,
         observer: (@Sendable (AdaptiveYADIFHandoffEvent) -> Void)? = nil) {
        self.gpu = gpu; self.gate = gate; self.observer = observer
    }
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
    deinit { diagnostics.flush(at: ProcessInfo.processInfo.systemUptime) }
#endif
    func cancelPendingWork() { limiter.cancel() }
    func submit(job: YADIFJob, outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
                completion: @escaping @Sendable (YADIFCommandCompletion) -> Void) throws(YADIFFailure) {
        guard let revision = limiter.admit() else { throw .commandBufferAllocationFailed }
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
        let admittedAt = ProcessInfo.processInfo.systemUptime
        let diagnostics = self.diagnostics
#endif
        let id = job.current.frame.accessUnitID
        let work = CPUWorkSlot(CPUYADIFWork(job: job, outputs: outputs))
        let finish = CPUOneShot<AdaptiveYADIFCompletion> { [limiter, observer] result in
            limiter.retire()
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
            let now = ProcessInfo.processInfo.systemUptime
            if result.mode == .cpu {
                diagnostics.completeCPU(success: result.completion.result == .completed,
                    queue: result.queueMilliseconds, fence: result.fenceMilliseconds,
                    processing: result.cpuProcessingMilliseconds, total: (now - admittedAt) * 1_000,
                    phases: result.phases, at: now)
            }
#endif
            observer?(.completed(id: id, mode: result.mode, result: result.completion.result,
                                 cpuProcessingMilliseconds: result.cpuProcessingMilliseconds))
            completion(result.completion)
        }
        lane.async { [self, work] in
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
            let queueMilliseconds = (ProcessInfo.processInfo.systemUptime - admittedAt) * 1_000
#endif
            guard limiter.isCurrent(revision) else {
                work.clear(); finish.call(.init(completion: .init(result: .failed), mode: nil)); return
            }
            do {
                var gpuCompletion: GPUSubmissionReturn<YADIFCommandCompletion>?
                let fence = try gate.withGPUAdmission { ticket in
                    let handoff = GPUSubmissionReturn<YADIFCommandCompletion> { result in
                        finish.call(.init(completion: result, mode: .gpu))
                        ticket.finish()
                    }
                    gpuCompletion = handoff
                    try gpu.submit(job: work.value!.job, outputs: work.value!.outputs) { result in
                        handoff.receive(result)
                    }
                }
                if let gpuCompletion {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                    diagnostics.select(.gpu, at: ProcessInfo.processInfo.systemUptime)
#endif
                    observer?(.modeSelected(id: id, mode: .gpu))
                    work.clear()
                    gpuCompletion.submissionReturned()
                    return
                }
                guard let fence else { preconditionFailure("Missing GPU completion owner") }
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                diagnostics.select(.cpu, at: ProcessInfo.processInfo.systemUptime)
#endif
                observer?(.modeSelected(id: id, mode: .cpu))
                observer?(.fenceWaitBegan(id: id))
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                let fenceStartedAt = ProcessInfo.processInfo.systemUptime
#endif
                let joined = fence.wait(timeout: .now() + .seconds(5))
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                let fenceMilliseconds = (ProcessInfo.processInfo.systemUptime - fenceStartedAt) * 1_000
#endif
                var cpuCompletion = AdaptiveYADIFCompletion(completion: .init(result: .failed), mode: .cpu)
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                cpuCompletion.queueMilliseconds = queueMilliseconds
                cpuCompletion.fenceMilliseconds = fenceMilliseconds
#endif
                guard joined, limiter.isCurrent(revision) else {
                    work.clear(); finish.call(cpuCompletion); return
                }
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                // Includes validation, pixel-buffer locking, parallel dispatch,
                // C processing and unlocking; excludes queueing and GPU wait.
                let startedAt = ProcessInfo.processInfo.systemUptime
                var phases: CPUYADIFProcessingTimings?
#endif
                let result: YADIFCommandResult
                do {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                    try CPUVideoProcessing.yadif(job: work.value!.job, outputs: work.value!.outputs) {
                        phases = $0
                    }
#else
                    try CPUVideoProcessing.yadif(job: work.value!.job, outputs: work.value!.outputs)
#endif
                    result = .completed
                } catch { result = .failed }
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                cpuCompletion.cpuProcessingMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                cpuCompletion.phases = phases
#endif
                cpuCompletion.completion = .init(result: result)
                work.clear()
                finish.call(cpuCompletion)
            } catch {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
                diagnostics.select(.gpu, at: ProcessInfo.processInfo.systemUptime)
#endif
                observer?(.modeSelected(id: id, mode: .gpu))
                work.clear(); finish.call(.init(completion: .init(result: .failed), mode: .gpu))
            }
        }
    }
}

private struct CPUScanWork: @unchecked Sendable {
    let current: CVPixelBuffer
    let previous: CVPixelBuffer
    let generation: MediaGeneration
}

final class AdaptiveLumaScanProbeBackend: LumaScanProbeBackend, @unchecked Sendable {
    private let gpu: any LumaScanProbeBackend
    private let gate: GPUVideoProcessingGate
    private let lane = DispatchQueue(label: "com.vplayer.scan-handoff", qos: .userInitiated)
    private let limiter = CPUWorkLimiter(maximum: 12)
    init(gpu: any LumaScanProbeBackend, gate: GPUVideoProcessingGate = .shared) {
        self.gpu = gpu; self.gate = gate
    }
    func cancelPendingWork() { limiter.cancel() }
    func submit(current: CVPixelBuffer, previous: CVPixelBuffer, generation: MediaGeneration,
                completion: @escaping @Sendable (Result<ContentProbeSample, LumaScanProbeFailure>) -> Void) throws(LumaScanProbeFailure) {
        guard let revision = limiter.admit() else { throw .resultBufferAllocationFailed }
        let work = CPUWorkSlot(CPUScanWork(current: current, previous: previous, generation: generation))
        let finish = CPUOneShot<Result<ContentProbeSample, LumaScanProbeFailure>> { [limiter] result in
            limiter.retire(); completion(result)
        }
        lane.async { [self, work] in
            guard limiter.isCurrent(revision) else { work.clear(); finish.call(.failure(.asynchronousCommandFailed)); return }
            do {
                var gpuCompletion: GPUSubmissionReturn<Result<ContentProbeSample, LumaScanProbeFailure>>?
                let fence = try gate.withGPUAdmission { ticket in
                    let handoff = GPUSubmissionReturn<Result<ContentProbeSample, LumaScanProbeFailure>> { result in
                        finish.call(result)
                        ticket.finish()
                    }
                    gpuCompletion = handoff
                    try gpu.submit(current: work.value!.current, previous: work.value!.previous,
                        generation: work.value!.generation) { result in handoff.receive(result) }
                }
                if let gpuCompletion {
                    work.clear()
                    gpuCompletion.submissionReturned()
                    return
                }
                guard let fence else { preconditionFailure("Missing GPU completion owner") }
                guard fence.wait(timeout: .now() + .seconds(5)), limiter.isCurrent(revision) else {
                    work.clear(); finish.call(.failure(.asynchronousCommandFailed)); return
                }
                let result = try CPUVideoProcessing.scan(current: work.value!.current, previous: work.value!.previous)
                work.clear()
                finish.call(.success(result))
            } catch let failure as LumaScanProbeFailure { work.clear(); finish.call(.failure(failure)) }
            catch { work.clear(); finish.call(.failure(.asynchronousCommandFailed)) }
        }
    }
}
#endif
