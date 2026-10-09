// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#if os(iOS)
import CoreVideo
import Foundation

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

/// A serial handoff lane does not replace the YADIF scheduler/window. It orders
/// admission to its existing GPU submitter or the identical CPU kernel. CPU
/// execution joins real prior GPU completion, and finishes before a later GPU
/// submission can leave this lane. The scheduler still bounds admitted jobs.
final class AdaptiveYADIFCommandSubmitter: YADIFCommandSubmitting, @unchecked Sendable {
    private let gpu: any YADIFCommandSubmitting
    private let gate: GPUVideoProcessingGate
    private let lane = DispatchQueue(label: "com.vplayer.yadif-handoff", qos: .userInitiated)
    private let limiter = CPUWorkLimiter(maximum: 3)
    init(gpu: any YADIFCommandSubmitting, gate: GPUVideoProcessingGate = .shared) {
        self.gpu = gpu; self.gate = gate
    }
    func cancelPendingWork() { limiter.cancel() }
    func submit(job: YADIFJob, outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
                completion: @escaping @Sendable (YADIFCommandCompletion) -> Void) throws(YADIFFailure) {
        guard let revision = limiter.admit() else { throw .commandBufferAllocationFailed }
        let work = CPUWorkSlot(CPUYADIFWork(job: job, outputs: outputs))
        let finish = CPUOneShot<YADIFCommandCompletion> { [limiter] result in
            limiter.retire()
            completion(result)
        }
        lane.async { [self, work] in
            guard limiter.isCurrent(revision) else { work.clear(); finish.call(.init(result: .failed)); return }
            do {
                var gpuCompletion: GPUSubmissionReturn<YADIFCommandCompletion>?
                let fence = try gate.withGPUAdmission { ticket in
                    let handoff = GPUSubmissionReturn<YADIFCommandCompletion> { result in
                        finish.call(result)
                        ticket.finish()
                    }
                    gpuCompletion = handoff
                    try gpu.submit(job: work.value!.job, outputs: work.value!.outputs) { result in
                        handoff.receive(result)
                    }
                }
                if let gpuCompletion {
                    work.clear()
                    gpuCompletion.submissionReturned()
                    return
                }
                guard let fence else { preconditionFailure("Missing GPU completion owner") }
                guard fence.wait(timeout: .now() + .seconds(5)), limiter.isCurrent(revision) else {
                    work.clear(); finish.call(.init(result: .failed)); return
                }
                try CPUVideoProcessing.yadif(job: work.value!.job, outputs: work.value!.outputs)
                work.clear()
                finish.call(.init(result: .completed))
            } catch { work.clear(); finish.call(.init(result: .failed)) }
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
