// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#if os(iOS)
import CoreVideo
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

struct CPUYADIFProcessingTimings: Sendable {
    var validationMilliseconds: Double = 0
    var inputLockMilliseconds: Double = 0
    var outputLockMilliseconds: Double = 0
    var parallelMilliseconds: Double = 0
    var unlockMilliseconds: Double = 0
}

enum CPUVideoProcessing {
    /// Timings are wall-clock observations, including synchronization/scheduling.
    /// They do not establish whether Core Video copied a surface. The optional
    /// callback runs synchronously, after all pixel buffers have been unlocked.
    static func yadif(job: YADIFJob, outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
                      timing: ((CPUYADIFProcessingTimings) -> Void)? = nil) throws(YADIFFailure) {
        var timings = CPUYADIFProcessingTimings()
        var locked: [(buffer: CVPixelBuffer, flags: CVPixelBufferLockFlags)] = []
        defer {
            let started = ProcessInfo.processInfo.systemUptime
            for entry in locked.reversed() { CVPixelBufferUnlockBaseAddress(entry.buffer, entry.flags) }
            timings.unlockMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            timing?(timings)
        }
        let inputs = [job.previous.frame.pixelBuffer, job.current.frame.pixelBuffer, job.next.frame.pixelBuffer]
        let outputBuffers = [outputs.first, outputs.second]
        let expected = YADIFSurfaceDescription(pixelBuffer: inputs[1])
        try measure(into: &timings.validationMilliseconds) { () throws(YADIFFailure) in
            try YADIFSurfaceValidator.validate(expected)
            for buffer in inputs + outputBuffers {
                guard YADIFSurfaceDescription(pixelBuffer: buffer) == expected else { throw .invalidPlaneLayout }
            }
            guard outputs.first !== outputs.second,
                  !inputs.contains(where: { $0 === outputs.first || $0 === outputs.second }) else {
                throw .invalidPlaneLayout
            }
        }
        try measure(into: &timings.inputLockMilliseconds) { () throws(YADIFFailure) in
            for buffer in inputs {
                if locked.contains(where: { $0.buffer === buffer }) { continue }
                guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw .invalidPlaneLayout }
                locked.append((buffer, .readOnly))
            }
        }
        try measure(into: &timings.outputLockMilliseconds) { () throws(YADIFFailure) in
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
        let workers = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        let result = CPUVideoResult()
        let parallelStartedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for operation in work where !operation.run(worker: worker, workers: workers) { result.recordFailure() }
        }
        timings.parallelMilliseconds = (ProcessInfo.processInfo.systemUptime - parallelStartedAt) * 1_000
        guard result.succeeded else { throw .commandFailed }
    }

    private static func measure(into milliseconds: inout Double,
                                _ operation: () throws(YADIFFailure) -> Void) throws(YADIFFailure) {
        let started = ProcessInfo.processInfo.systemUptime
        defer { milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000 }
        try operation()
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
