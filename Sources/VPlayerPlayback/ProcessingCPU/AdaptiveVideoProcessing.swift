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
        let work = CPUYADIFWork(job: job, outputs: outputs)
        let finish = CPUOneShot<YADIFCommandCompletion> { [limiter] result in
            limiter.retire()
            completion(result)
        }
        lane.async { [self, work] in
            guard limiter.isCurrent(revision) else { finish.call(.init(result: .failed)); return }
            do {
                let fence = try gate.withGPUAdmission { ticket in
                    try gpu.submit(job: work.job, outputs: work.outputs) { result in
                        finish.call(result)
                        ticket.finish()
                    }
                }
                guard let fence else { return }
                guard fence.wait(timeout: .now() + .seconds(5)), limiter.isCurrent(revision) else {
                    finish.call(.init(result: .failed)); return
                }
                try CPUVideoProcessing.yadif(job: work.job, outputs: work.outputs)
                finish.call(.init(result: .completed))
            } catch { finish.call(.init(result: .failed)) }
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
        let work = CPUScanWork(current: current, previous: previous, generation: generation)
        let finish = CPUOneShot<Result<ContentProbeSample, LumaScanProbeFailure>> { [limiter] result in
            limiter.retire(); completion(result)
        }
        lane.async { [self, work] in
            guard limiter.isCurrent(revision) else { finish.call(.failure(.asynchronousCommandFailed)); return }
            do {
                let fence = try gate.withGPUAdmission { ticket in
                    try gpu.submit(current: work.current, previous: work.previous, generation: work.generation) { result in
                        finish.call(result)
                        ticket.finish()
                    }
                }
                guard let fence else { return }
                guard fence.wait(timeout: .now() + .seconds(5)), limiter.isCurrent(revision) else {
                    finish.call(.failure(.asynchronousCommandFailed)); return
                }
                finish.call(.success(try CPUVideoProcessing.scan(current: work.current, previous: work.previous)))
            } catch let failure as LumaScanProbeFailure { finish.call(.failure(failure)) }
            catch { finish.call(.failure(.asynchronousCommandFailed)) }
        }
    }
}
#endif
