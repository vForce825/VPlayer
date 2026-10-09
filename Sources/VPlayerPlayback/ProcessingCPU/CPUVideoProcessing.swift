// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#if os(iOS)
import CoreVideo
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
import Darwin
#endif
import Foundation

private struct CPUPlaneOperation: @unchecked Sendable {
    let previous: UnsafeMutablePointer<UInt8>
    let current: UnsafeMutablePointer<UInt8>
    let next: UnsafeMutablePointer<UInt8>
    let output: UnsafeMutablePointer<UInt8>
    let previousStride: Int
    let currentStride: Int
    let nextStride: Int
    let outputStride: Int
    let width: Int32
    let height: Int32
    let components: Int32
    let depth: Int32
    let outputIndex: Int32
    let topFieldFirst: Int32
    let spatialOnly: Int32
    func run(worker: Int, workers: Int) -> Bool {
        let start = Int(height) * worker / workers
        let end = Int(height) * (worker + 1) / workers
        return VPYADIFProcessPlaneRows(previous, previousStride, current, currentStride,
            next, nextStride, output, outputStride, width, height, components, depth,
            outputIndex, topFieldFirst, spatialOnly, Int32(start), Int32(end - start)) == 0
    }
}

private final class CPUVideoResult: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func recordFailure() { lock.withLock { failed = true } }
    var succeeded: Bool { lock.withLock { !failed } }
}

#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
enum CPUYADIFThreadClock {
    /// Calling-thread user + kernel service time. Failure is missing evidence,
    /// never a successful zero. This clock does not identify a physical core.
    static func milliseconds() -> Double? {
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0,
              value.tv_sec >= 0, value.tv_nsec >= 0, value.tv_nsec < 1_000_000_000 else { return nil }
        return Double(value.tv_sec) * 1_000 + Double(value.tv_nsec) / 1_000_000
    }

    static func elapsedMilliseconds(start: Double?, end: Double?) -> Double? {
        guard let start, let end, start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
        return end - start
    }
}

enum CPUYADIFRequestedQoS: Sendable {
    case userInteractive, userInitiated, `default`, utility, background, unspecified, unknown

    /// qos_class_self reports requested QoS, not effective CPU entitlement.
    static func current() -> Self {
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE: return .userInteractive
        case QOS_CLASS_USER_INITIATED: return .userInitiated
        case QOS_CLASS_DEFAULT: return .default
        case QOS_CLASS_UTILITY: return .utility
        case QOS_CLASS_BACKGROUND: return .background
        case QOS_CLASS_UNSPECIFIED: return .unspecified
        default: return .unknown
        }
    }
}

struct CPUYADIFRequestedQoSCounts: Sendable {
    var userInteractive: UInt64 = 0
    var userInitiated: UInt64 = 0
    var `default`: UInt64 = 0
    var utility: UInt64 = 0
    var background: UInt64 = 0
    var unspecified: UInt64 = 0
    var unknown: UInt64 = 0

    mutating func record(_ value: CPUYADIFRequestedQoS) {
        switch value {
        case .userInteractive: userInteractive += 1
        case .userInitiated: userInitiated += 1
        case .default: self.default += 1
        case .utility: utility += 1
        case .background: background += 1
        case .unspecified: unspecified += 1
        case .unknown: unknown += 1
        }
    }

    mutating func merge(_ other: Self) {
        userInteractive += other.userInteractive
        userInitiated += other.userInitiated
        self.default += other.default
        utility += other.utility
        background += other.background
        unspecified += other.unspecified
        unknown += other.unknown
    }

    var logValue: String {
        "\(userInteractive)/\(userInitiated)/\(self.default)/\(utility)/\(background)/\(unspecified)/\(unknown)"
    }
}

struct CPUYADIFMeasuredDurations: Sendable {
    var count: UInt64 = 0
    var totalMilliseconds: Double = 0
    var minimumMilliseconds: Double?
    var maximumMilliseconds: Double = 0

    mutating func record(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        count += 1
        totalMilliseconds += value
        minimumMilliseconds = min(minimumMilliseconds ?? value, value)
        maximumMilliseconds = max(maximumMilliseconds, value)
    }

    mutating func merge(_ other: Self) {
        guard other.count > 0 else { return }
        count += other.count
        totalMilliseconds += other.totalMilliseconds
        if let minimum = other.minimumMilliseconds {
            minimumMilliseconds = min(minimumMilliseconds ?? minimum, minimum)
        }
        maximumMilliseconds = max(maximumMilliseconds, other.maximumMilliseconds)
    }
}

struct CPUYADIFWorkerObservation: Sendable {
    let startedAt: TimeInterval
    let endedAt: TimeInterval
    let cpuMilliseconds: Double?
    let requestedQoSStart: CPUYADIFRequestedQoS
    let requestedQoSEnd: CPUYADIFRequestedQoS
}

struct CPUYADIFWorkerSummary: Sendable {
    let expectedWorkers: UInt64
    var cpu = CPUYADIFMeasuredDurations()
    var wall = CPUYADIFMeasuredDurations()
    var startDelay = CPUYADIFMeasuredDurations()
    var startSpreadMilliseconds: Double?
    var joinTailMilliseconds: Double?
    var requestedQoSStart = CPUYADIFRequestedQoSCounts()
    var requestedQoSEnd = CPUYADIFRequestedQoSCounts()

    init<Observations: Sequence>(observations: Observations, workers: Int,
        parallelStartedAt: TimeInterval, parallelEndedAt: TimeInterval)
        where Observations.Element == CPUYADIFWorkerObservation? {
        precondition((1...4).contains(workers))
        expectedWorkers = UInt64(workers)
        var lastEnd: TimeInterval?
        for case let observation? in observations.prefix(workers) {
            wall.record((observation.endedAt - observation.startedAt) * 1_000)
            startDelay.record((observation.startedAt - parallelStartedAt) * 1_000)
            if let service = observation.cpuMilliseconds { cpu.record(service) }
            requestedQoSStart.record(observation.requestedQoSStart)
            requestedQoSEnd.record(observation.requestedQoSEnd)
            lastEnd = max(lastEnd ?? observation.endedAt, observation.endedAt)
        }
        if wall.count == expectedWorkers, startDelay.count == expectedWorkers,
           let firstDelay = startDelay.minimumMilliseconds, let lastEnd {
            startSpreadMilliseconds = startDelay.maximumMilliseconds - firstDelay
            joinTailMilliseconds = max(0, parallelEndedAt - lastEnd) * 1_000
        }
    }
}

/// One allocation, at most four disjoint initialized elements. Each iteration
/// writes only its own element once. Reads/destruction occur only after the
/// synchronous concurrentPerform join; no shared Swift Array mutation occurs.
private final class CPUYADIFWorkerSlots: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<CPUYADIFWorkerObservation?>
    private let count: Int
    init(count: Int) {
        precondition((1...4).contains(count))
        self.count = count
        storage = .allocate(capacity: count)
        storage.initialize(repeating: nil, count: count)
    }
    deinit { storage.deinitialize(count: count); storage.deallocate() }
    func record(_ observation: CPUYADIFWorkerObservation, worker: Int) {
        precondition((0..<count).contains(worker))
        storage.advanced(by: worker).pointee = observation
    }
    func summary(parallelStartedAt: TimeInterval, parallelEndedAt: TimeInterval) -> CPUYADIFWorkerSummary {
        CPUYADIFWorkerSummary(observations: UnsafeBufferPointer(start: storage, count: count),
            workers: count, parallelStartedAt: parallelStartedAt, parallelEndedAt: parallelEndedAt)
    }
}

struct CPUYADIFProcessingContext: Sendable, Equatable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let depth: Int
    let workers: Int
    let activeProcessors: Int
}
#endif

/// The timing callback is active only in Debug or explicitly enabled diagnostic
/// builds. Shipping Release compiles out its storage, clocks and callbacks.
struct CPUYADIFProcessingTimings: Sendable {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
    var validationMilliseconds: Double = 0
    var inputLockMilliseconds: Double = 0
    var outputLockMilliseconds: Double = 0
    var parallelMilliseconds: Double = 0
    var unlockMilliseconds: Double = 0
    var workers: CPUYADIFWorkerSummary?
    var context: CPUYADIFProcessingContext?
#endif
}

enum CPUVideoProcessing {
    /// Phase timings are wall-clock observations, including scheduling. Optional
    /// worker diagnostics additionally measure calling-thread CPU service. Their
    /// clock/QoS sampling has overhead and is disabled when timing is nil.
    /// All measurements are compiled out of shipping Release.
    /// They do not establish whether Core Video copied a surface. In diagnostic
    /// builds the callback runs synchronously after all buffers are unlocked;
    /// shipping Release never invokes it, including when a callback is supplied.
    static func yadif(job: YADIFJob, outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
                      timing: ((CPUYADIFProcessingTimings) -> Void)? = nil) throws(YADIFFailure) {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
        var timings = CPUYADIFProcessingTimings()
#endif
        var locked: [(buffer: CVPixelBuffer, flags: CVPixelBufferLockFlags)] = []
        defer {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
            let started = timing == nil ? nil : ProcessInfo.processInfo.systemUptime
#endif
            for entry in locked.reversed() { CVPixelBufferUnlockBaseAddress(entry.buffer, entry.flags) }
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
            if let started { timings.unlockMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000 }
            timing?(timings)
#endif
        }
        let inputs = [job.previous.frame.pixelBuffer, job.current.frame.pixelBuffer, job.next.frame.pixelBuffer]
        let outputBuffers = [outputs.first, outputs.second]
        let expected = YADIFSurfaceDescription(pixelBuffer: inputs[1])
        do {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
            let started = timing == nil ? nil : ProcessInfo.processInfo.systemUptime
            defer { if let started { timings.validationMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000 } }
#endif
            try YADIFSurfaceValidator.validate(expected)
            for buffer in inputs + outputBuffers {
                guard YADIFSurfaceDescription(pixelBuffer: buffer) == expected else { throw .invalidPlaneLayout }
            }
            guard outputs.first !== outputs.second,
                  !inputs.contains(where: { $0 === outputs.first || $0 === outputs.second }) else {
                throw .invalidPlaneLayout
            }
        }
        do {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
            let started = timing == nil ? nil : ProcessInfo.processInfo.systemUptime
            defer { if let started { timings.inputLockMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000 } }
#endif
            for buffer in inputs {
                if locked.contains(where: { $0.buffer === buffer }) { continue }
                guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw .invalidPlaneLayout }
                locked.append((buffer, .readOnly))
            }
        }
        do {
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
            let started = timing == nil ? nil : ProcessInfo.processInfo.systemUptime
            defer { if let started { timings.outputLockMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000 } }
#endif
            for buffer in outputBuffers {
                guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw .invalidPlaneLayout }
                locked.append((buffer, []))
            }
        }
        let depth: Int32 = expected.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            expected.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 10 : 8
        var operations: [CPUPlaneOperation] = []
        operations.reserveCapacity(4)
        for (index, output) in outputBuffers.enumerated() {
            for plane in 0..<2 {
                guard let previous = CVPixelBufferGetBaseAddressOfPlane(inputs[0], plane),
                      let current = CVPixelBufferGetBaseAddressOfPlane(inputs[1], plane),
                      let next = CVPixelBufferGetBaseAddressOfPlane(inputs[2], plane),
                      let destination = CVPixelBufferGetBaseAddressOfPlane(output, plane) else { throw .invalidPlaneLayout }
                operations.append(CPUPlaneOperation(previous: previous.assumingMemoryBound(to: UInt8.self),
                    current: current.assumingMemoryBound(to: UInt8.self), next: next.assumingMemoryBound(to: UInt8.self),
                    output: destination.assumingMemoryBound(to: UInt8.self),
                    previousStride: CVPixelBufferGetBytesPerRowOfPlane(inputs[0], plane),
                    currentStride: CVPixelBufferGetBytesPerRowOfPlane(inputs[1], plane),
                    nextStride: CVPixelBufferGetBytesPerRowOfPlane(inputs[2], plane),
                    outputStride: CVPixelBufferGetBytesPerRowOfPlane(output, plane),
                    width: Int32(CVPixelBufferGetWidthOfPlane(output, plane)),
                    height: Int32(CVPixelBufferGetHeightOfPlane(output, plane)), components: plane == 0 ? 1 : 2,
                    depth: depth, outputIndex: Int32(index), topFieldFirst: job.order.parity == .top ? 1 : 0,
                    spatialOnly: job.spatialOnly ? 1 : 0))
            }
        }
        let work = operations
        let activeProcessors = ProcessInfo.processInfo.activeProcessorCount
        let workers = max(1, min(4, activeProcessors))
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
        let observations = timing == nil ? nil : CPUYADIFWorkerSlots(count: workers)
        if timing != nil {
            timings.context = CPUYADIFProcessingContext(width: expected.width, height: expected.height,
                pixelFormat: expected.pixelFormat, depth: Int(depth), workers: workers,
                activeProcessors: activeProcessors)
        }
#endif
        let result = CPUVideoResult()
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
        let parallelStartedAt = timing == nil ? nil : ProcessInfo.processInfo.systemUptime
#endif
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
            guard let observations else {
                for operation in work where !operation.run(worker: worker, workers: workers) { result.recordFailure() }
                return
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let requestedQoSStart = CPUYADIFRequestedQoS.current()
            let cpuStart = CPUYADIFThreadClock.milliseconds()
            for operation in work where !operation.run(worker: worker, workers: workers) { result.recordFailure() }
            let cpuEnd = CPUYADIFThreadClock.milliseconds()
            let endedAt = ProcessInfo.processInfo.systemUptime
            let requestedQoSEnd = CPUYADIFRequestedQoS.current()
            observations.record(CPUYADIFWorkerObservation(startedAt: startedAt, endedAt: endedAt,
                cpuMilliseconds: CPUYADIFThreadClock.elapsedMilliseconds(start: cpuStart, end: cpuEnd),
                requestedQoSStart: requestedQoSStart, requestedQoSEnd: requestedQoSEnd), worker: worker)
#else
            for operation in work where !operation.run(worker: worker, workers: workers) { result.recordFailure() }
#endif
        }
#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS
        if let parallelStartedAt {
            let parallelEndedAt = ProcessInfo.processInfo.systemUptime
            timings.parallelMilliseconds = (parallelEndedAt - parallelStartedAt) * 1_000
            timings.workers = observations?.summary(parallelStartedAt: parallelStartedAt, parallelEndedAt: parallelEndedAt)
        }
#endif
        guard result.succeeded else { throw .commandFailed }
    }

    static func scan(current: CVPixelBuffer, previous: CVPixelBuffer) throws(LumaScanProbeFailure) -> ContentProbeSample {
        let properties = LumaScanPixelBufferProperties(pixelBuffer: current)
        _ = try LumaScanInputValidator.validate(current: properties,
            previous: LumaScanPixelBufferProperties(pixelBuffer: previous))
        guard CVPixelBufferLockBaseAddress(current, .readOnly) == kCVReturnSuccess else { throw .invalidDimensions }
        defer { CVPixelBufferUnlockBaseAddress(current, .readOnly) }
        let distinct = current !== previous
        if distinct {
            guard CVPixelBufferLockBaseAddress(previous, .readOnly) == kCVReturnSuccess else { throw .invalidDimensions }
        }
        defer { if distinct { CVPixelBufferUnlockBaseAddress(previous, .readOnly) } }
        guard let c = CVPixelBufferGetBaseAddressOfPlane(current, 0),
              let p = CVPixelBufferGetBaseAddressOfPlane(previous, 0) else { throw .invalidDimensions }
        let depth: Int32 = properties.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            properties.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 10 : 8
        var comb: UInt64 = 0
        var motion: UInt64 = 0
        guard VPProbeLumaCPU(c.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(current, 0),
            p.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(previous, 0),
            Int32(properties.lumaWidth), Int32(properties.lumaHeight), depth, &comb, &motion) == 0 else { throw .invalidDimensions }
        let divisor = Float(UInt64(UInt16.max) * UInt64(LumaScanProbeLayout.sampleCount))
        return ContentProbeSample(combRatio: Float(comb) / divisor, motionRatio: Float(motion) / divisor,
            sampleCount: LumaScanProbeLayout.sampleCount)
    }
}

#endif
