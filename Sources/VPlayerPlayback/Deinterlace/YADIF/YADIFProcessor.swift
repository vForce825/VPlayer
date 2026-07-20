// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import Metal

typealias YADIFOutputAllocator = @Sendable (
    _ source: CVPixelBuffer
) throws(YADIFFailure) -> (first: CVPixelBuffer, second: CVPixelBuffer)

public enum YADIFDropReason: UInt8, Sendable, Equatable {
    case gpuQueueFull
}

public struct YADIFDropEvent: Sendable, Equatable {
    public let reason: YADIFDropReason
    public let sourceAccessUnitID: UInt64
    public let presentationTimeStamp: CMTime

    public init(
        reason: YADIFDropReason,
        sourceAccessUnitID: UInt64,
        presentationTimeStamp: CMTime
    ) {
        self.reason = reason
        self.sourceAccessUnitID = sourceAccessUnitID
        self.presentationTimeStamp = presentationTimeStamp
    }
}

public struct YADIFProcessorMetrics: Sendable, Equatable {
    public let inFlightCount: Int
    public let pendingFrameCount: Int
    public let submittedJobCount: UInt64
    public let completedJobCount: UInt64
    public let gpuQueueFullDropCount: UInt64
    public let staleGenerationDropCount: UInt64

    public init(
        inFlightCount: Int,
        pendingFrameCount: Int,
        submittedJobCount: UInt64,
        completedJobCount: UInt64,
        gpuQueueFullDropCount: UInt64,
        staleGenerationDropCount: UInt64
    ) {
        self.inFlightCount = inFlightCount
        self.pendingFrameCount = pendingFrameCount
        self.submittedJobCount = submittedJobCount
        self.completedJobCount = completedJobCount
        self.gpuQueueFullDropCount = gpuQueueFullDropCount
        self.staleGenerationDropCount = staleGenerationDropCount
    }
}

final class YADIFSystemCommandSubmitter: YADIFCommandSubmitting, @unchecked Sendable {
    private final class PendingResources: @unchecked Sendable {
        private var encoded: YADIFEncodedResources?

        init(_ encoded: YADIFEncodedResources) {
            self.encoded = encoded
        }

        func releaseBeforeUserCompletion() {
            encoded = nil
        }
    }

    private let commandQueue: any MTLCommandQueue
    private let kernel: YADIFNV12Kernel

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        textureCache: CVMetalTextureCache
    ) throws(YADIFFailure) {
        self.commandQueue = commandQueue
        let mapper = try YADIFTextureMapper(
            device: device,
            textureCache: textureCache
        )
        kernel = try YADIFNV12Kernel(device: device, textureMapper: mapper)
    }

    func submit(
        job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
        completion: @escaping @Sendable (YADIFCommandResult) -> Void
    ) throws(YADIFFailure) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw .commandBufferAllocationFailed
        }
        let resources = PendingResources(
            try kernel.encode(job, outputs: outputs, into: commandBuffer)
        )
        commandBuffer.addCompletedHandler { buffer in
            resources.releaseBeforeUserCompletion()
            completion(buffer.status == .completed ? .completed : .failed)
        }
        commandBuffer.commit()
    }
}

public final class YADIFProcessor: VideoFrameProcessing, @unchecked Sendable {
    public let requiredInputFrameCount = 3

    private typealias Completion = @Sendable (
        Result<[VideoPresentationFrame], PlaybackFailure>
    ) -> Void

    private struct InputKey: Hashable, Sendable {
        let generation: MediaGeneration
        let accessUnitID: UInt64
        let pixelBuffer: ObjectIdentifier

        init(_ frame: NormalizedDecodedFrame) {
            generation = frame.frame.generation
            accessUnitID = frame.frame.accessUnitID
            pixelBuffer = ObjectIdentifier(frame.frame.pixelBuffer)
        }
    }

    private struct ReadyJob: @unchecked Sendable {
        let job: YADIFJob
        let completion: Completion
        let firstSequenceNumber: UInt64
        let epoch: UInt64
    }

    private struct InFlightJob: @unchecked Sendable {
        let ready: ReadyJob
        let outputs: (first: CVPixelBuffer, second: CVPixelBuffer)
    }

    private struct SubmissionAttempt: @unchecked Sendable {
        let ready: ReadyJob
        var completionIsOpen: Bool
    }

    private struct Counters: Sendable {
        var submitted: UInt64 = 0
        var completed: UInt64 = 0
        var gpuQueueFullDrops: UInt64 = 0
        var staleGenerationDrops: UInt64 = 0
    }

    private enum UserAction: @unchecked Sendable {
        case complete(Completion, Result<[VideoPresentationFrame], PlaybackFailure>)
        case drop(@Sendable (YADIFDropEvent) -> Void, YADIFDropEvent)

        func perform() {
            switch self {
            case let .complete(completion, result):
                completion(result)
            case let .drop(sink, event):
                sink(event)
            }
        }
    }

    private enum ConfigurationFailure: Error {
        case invalidMaximumInFlight
        case invalidMaximumPendingFrames
    }

    private let lock = NSLock()
    private let commandSubmitter: any YADIFCommandSubmitting
    private let surfacePool: ProgressiveSurfacePool
    private let outputAllocator: YADIFOutputAllocator
    private let clock: any PlaybackClock
    private let maximumInFlight: Int
    private let maximumPendingFrames: Int
    private let dropSink: @Sendable (YADIFDropEvent) -> Void

    private var generation = MediaGeneration(rawValue: 0)
    private var segmentEpoch: UInt64 = 0
    private var window = YADIFReferenceWindow(generation: MediaGeneration(rawValue: 0))
    private var pendingCompletions: [InputKey: [Completion]] = [:]
    private var readyJobs: [ReadyJob] = []
    private var submissionAttempts: [UInt64: SubmissionAttempt] = [:]
    private var inFlightJobs: [UInt64: InFlightJob] = [:]
    private var nextInFlightIdentifier: UInt64 = 1
    private var nextSequenceNumber: UInt64 = 1
    private var counters = Counters()
    private var isDraining = false
    private var drainBarriers: [Completion] = []
    private var schedulerIsRunning = false

    public convenience init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        textureCache: CVMetalTextureCache,
        clock: any PlaybackClock,
        maximumInFlight: Int = 3,
        maximumPendingFrames: Int = 4,
        dropSink: @escaping @Sendable (YADIFDropEvent) -> Void = { _ in }
    ) throws {
        let submitter = try YADIFSystemCommandSubmitter(
            device: device,
            commandQueue: commandQueue,
            textureCache: textureCache
        )
        try self.init(
            commandSubmitter: submitter,
            surfacePool: ProgressiveSurfacePool(),
            clock: clock,
            maximumInFlight: maximumInFlight,
            maximumPendingFrames: maximumPendingFrames,
            dropSink: dropSink
        )
    }

    init(
        commandSubmitter: any YADIFCommandSubmitting,
        surfacePool: ProgressiveSurfacePool,
        outputAllocator: YADIFOutputAllocator? = nil,
        clock: any PlaybackClock,
        maximumInFlight: Int = 3,
        maximumPendingFrames: Int = 4,
        dropSink: @escaping @Sendable (YADIFDropEvent) -> Void = { _ in }
    ) throws {
        guard (1...3).contains(maximumInFlight) else {
            throw ConfigurationFailure.invalidMaximumInFlight
        }
        guard maximumPendingFrames >= 1 else {
            throw ConfigurationFailure.invalidMaximumPendingFrames
        }
        self.commandSubmitter = commandSubmitter
        self.surfacePool = surfacePool
        if let outputAllocator {
            self.outputAllocator = outputAllocator
        } else {
            let defaultOutputAllocator: YADIFOutputAllocator = { source in
                try surfacePool.allocatePair(matching: source)
            }
            self.outputAllocator = defaultOutputAllocator
        }
        self.clock = clock
        self.maximumInFlight = maximumInFlight
        self.maximumPendingFrames = maximumPendingFrames
        self.dropSink = dropSink
    }

    public func reset(to generation: MediaGeneration) {
        var actions: [UserAction] = []
        lock.lock()
        resetLocked(to: generation, actions: &actions)
        lock.unlock()
        perform(actions)
        driveScheduler()
    }

    public func submit(
        _ frame: DecodedVideoFrame,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        guard frame.presentationTimeStamp.isNumeric,
              frame.duration.isNumeric,
              CMTimeCompare(frame.duration, .zero) > 0 else {
            completion(.failure(Self.invalidTimingFailure))
            return
        }
        let fieldDuration = CMTimeMultiplyByRatio(
            frame.duration,
            multiplier: 1,
            divisor: 2
        )
        guard fieldDuration.isNumeric,
              CMTimeCompare(fieldDuration, .zero) > 0 else {
            completion(.failure(Self.invalidTimingFailure))
            return
        }
        let order: ResolvedFieldOrder
        if let coded = frame.parserMetadata.fieldOrder,
           coded != .unknown,
           coded != .progressive {
            order = ResolvedFieldOrder(coded: coded)
        } else if let topFieldFirst = frame.parserMetadata.topFieldFirst {
            order = ResolvedFieldOrder(
                parity: topFieldFirst ? .top : .bottom,
                confidence: .signaled,
                source: .parser
            )
        } else {
            order = ResolvedFieldOrder(
                parity: .top,
                confidence: .assumed,
                source: .none
            )
        }
        submit(
            normalized: NormalizedDecodedFrame(
                frame: frame,
                presentationTimeStamp: frame.presentationTimeStamp,
                frameDuration: frame.duration,
                fieldDuration: fieldDuration,
                timingWasSynthesized: false,
                provenance: .decodedCallbackDuration
            ),
            order: order,
            completion: completion
        )
    }

    func submit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity: Bool = false,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        var actions: [UserAction] = []
        lock.lock()
        if isDraining {
            actions.append(.complete(completion, .success([])))
        } else if frame.frame.generation < generation {
            counters.staleGenerationDrops &+= 1
            actions.append(.complete(completion, .success([])))
        } else {
            if frame.frame.generation > generation {
                resetLocked(to: frame.frame.generation, actions: &actions)
            }
            pendingCompletions[InputKey(frame), default: []].append(completion)
            let transition = window.push(
                frame,
                order: order,
                discontinuity: discontinuity
            )
            consumeLocked(transition, actions: &actions)
            enforcePendingBoundLocked(actions: &actions)
            finishDrainIfPossibleLocked(actions: &actions)
        }
        lock.unlock()
        perform(actions)
        driveScheduler()
    }

    public func drain(
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        var actions: [UserAction] = []
        lock.lock()
        isDraining = true
        drainBarriers.append(completion)
        consumeLocked(window.drain(), actions: &actions)
        enforcePendingBoundLocked(actions: &actions)
        finishDrainIfPossibleLocked(actions: &actions)
        lock.unlock()
        perform(actions)
        driveScheduler()
    }

    public var metricsSnapshot: YADIFProcessorMetrics {
        lock.lock()
        defer { lock.unlock() }
        return YADIFProcessorMetrics(
            inFlightCount: activeInFlightCountLocked,
            pendingFrameCount: readyJobs.count + window.unemittedCount,
            submittedJobCount: counters.submitted,
            completedJobCount: counters.completed,
            gpuQueueFullDropCount: counters.gpuQueueFullDrops,
            staleGenerationDropCount: counters.staleGenerationDrops
        )
    }

    private var activeInFlightCountLocked: Int {
        inFlightJobs.values.reduce(into: 0) { count, item in
            if isCurrentLocked(item.ready) { count += 1 }
        }
    }

    private var occupiedSubmissionSlotCountLocked: Int {
        inFlightJobs.count + submissionAttempts.count
    }

    private func isCurrentLocked(_ ready: ReadyJob) -> Bool {
        ready.epoch == segmentEpoch
            && ready.job.current.frame.generation == generation
    }

    private func consumeLocked(
        _ transition: YADIFReferenceWindow.Transition,
        actions: inout [UserAction]
    ) {
        for discarded in transition.discarded {
            if let completion = popPendingCompletionLocked(for: discarded) {
                actions.append(.complete(completion, .success([])))
            }
        }
        guard let job = transition.job,
              let completion = popPendingCompletionLocked(for: job.current) else {
            return
        }
        let firstSequence = nextSequenceNumber
        nextSequenceNumber &+= 2
        readyJobs.append(ReadyJob(
            job: job,
            completion: completion,
            firstSequenceNumber: firstSequence,
            epoch: segmentEpoch
        ))
    }

    private func popPendingCompletionLocked(
        for frame: NormalizedDecodedFrame
    ) -> Completion? {
        let key = InputKey(frame)
        guard var completions = pendingCompletions[key], !completions.isEmpty else {
            return nil
        }
        let completion = completions.removeFirst()
        if completions.isEmpty {
            pendingCompletions.removeValue(forKey: key)
        } else {
            pendingCompletions[key] = completions
        }
        return completion
    }

    private func driveScheduler() {
        lock.lock()
        guard !schedulerIsRunning else {
            lock.unlock()
            return
        }
        schedulerIsRunning = true
        lock.unlock()

        while true {
            var actions: [UserAction] = []
            lock.lock()
            if occupiedSubmissionSlotCountLocked < maximumInFlight, !readyJobs.isEmpty {
                let identifier = nextInFlightIdentifier
                nextInFlightIdentifier &+= 1
                submissionAttempts[identifier] = SubmissionAttempt(
                    ready: readyJobs.removeFirst(),
                    completionIsOpen: true
                )
                lock.unlock()
                executeSubmissionAttempt(identifier: identifier)
                continue
            }

            enforcePendingBoundLocked(actions: &actions)
            finishDrainIfPossibleLocked(actions: &actions)
            schedulerIsRunning = false
            lock.unlock()
            perform(actions)
            return
        }
    }

    private func executeSubmissionAttempt(identifier: UInt64) {
        lock.lock()
        guard let selected = submissionAttempts[identifier] else {
            lock.unlock()
            return
        }
        lock.unlock()

        let outputs: (first: CVPixelBuffer, second: CVPixelBuffer)
        do {
            outputs = try outputAllocator(selected.ready.job.current.frame.pixelBuffer)
        } catch let failure {
            var actions: [UserAction] = []
            lock.lock()
            if let attempt = submissionAttempts.removeValue(forKey: identifier),
               attempt.completionIsOpen {
                actions.append(.complete(
                    attempt.ready.completion,
                    .failure(Self.playbackFailure(for: failure))
                ))
            }
            finishDrainIfPossibleLocked(actions: &actions)
            lock.unlock()
            perform(actions)
            return
        }

        lock.lock()
        guard let attempt = submissionAttempts.removeValue(forKey: identifier) else {
            lock.unlock()
            return
        }
        guard attempt.completionIsOpen,
              isCurrentLocked(attempt.ready) else {
            var actions: [UserAction] = []
            finishDrainIfPossibleLocked(actions: &actions)
            lock.unlock()
            perform(actions)
            return
        }
        inFlightJobs[identifier] = InFlightJob(ready: attempt.ready, outputs: outputs)
        counters.submitted &+= 1
        lock.unlock()

        do {
            try commandSubmitter.submit(
                job: attempt.ready.job,
                outputs: outputs
            ) { result in
                self.commandCompleted(identifier: identifier, result: result)
            }
        } catch let failure {
            var actions: [UserAction] = []
            lock.lock()
            if let rolledBack = inFlightJobs.removeValue(forKey: identifier) {
                if isCurrentLocked(rolledBack.ready) {
                    counters.submitted -= 1
                    actions.append(.complete(
                        rolledBack.ready.completion,
                        .failure(Self.playbackFailure(for: failure))
                    ))
                } else {
                    actions.append(.complete(rolledBack.ready.completion, .success([])))
                }
            }
            finishDrainIfPossibleLocked(actions: &actions)
            lock.unlock()
            perform(actions)
        }
    }

    private func enforcePendingBoundLocked(actions: inout [UserAction]) {
        while occupiedSubmissionSlotCountLocked >= maximumInFlight,
              readyJobs.count + window.unemittedCount > maximumPendingFrames,
              !readyJobs.isEmpty {
            let now = clock.currentTime
            let lateIndex = now.isNumeric ? readyJobs.firstIndex { ready in
                let secondFieldEnd = CMTimeAdd(
                    ready.job.current.presentationTimeStamp,
                    CMTimeMultiply(ready.job.current.fieldDuration, multiplier: 2)
                )
                return secondFieldEnd.isNumeric
                    && CMTimeCompare(secondFieldEnd, now) <= 0
            } : nil
            let dropped = readyJobs.remove(at: lateIndex ?? readyJobs.startIndex)
            counters.gpuQueueFullDrops &+= 1
            actions.append(.complete(dropped.completion, .success([])))
            actions.append(.drop(dropSink, YADIFDropEvent(
                reason: .gpuQueueFull,
                sourceAccessUnitID: dropped.job.current.frame.accessUnitID,
                presentationTimeStamp: dropped.job.current.presentationTimeStamp
            )))
        }
    }

    private func commandCompleted(
        identifier: UInt64,
        result: YADIFCommandResult
    ) {
        var actions: [UserAction] = []
        lock.lock()
        guard let completed = inFlightJobs.removeValue(forKey: identifier) else {
            lock.unlock()
            return
        }
        let isCurrent = isCurrentLocked(completed.ready)
        if isCurrent {
            counters.completed &+= 1
        }
        if !isCurrent {
            actions.append(.complete(completed.ready.completion, .success([])))
        } else {
            switch result {
            case .completed:
                actions.append(.complete(
                    completed.ready.completion,
                    .success(Self.presentationFrames(for: completed))
                ))
            case .failed:
                actions.append(.complete(
                    completed.ready.completion,
                    .failure(Self.commandFailure)
                ))
            }
        }
        finishDrainIfPossibleLocked(actions: &actions)
        lock.unlock()
        perform(actions)
        driveScheduler()
    }

    private func resetLocked(
        to generation: MediaGeneration,
        actions: inout [UserAction]
    ) {
        segmentEpoch &+= 1
        _ = window.reset(generation: generation)
        for completions in pendingCompletions.values {
            for completion in completions {
                actions.append(.complete(completion, .success([])))
            }
        }
        pendingCompletions.removeAll(keepingCapacity: true)
        for ready in readyJobs {
            actions.append(.complete(ready.completion, .success([])))
        }
        readyJobs.removeAll(keepingCapacity: true)
        for identifier in Array(submissionAttempts.keys) {
            guard var attempt = submissionAttempts[identifier],
                  attempt.completionIsOpen else {
                continue
            }
            actions.append(.complete(attempt.ready.completion, .success([])))
            attempt.completionIsOpen = false
            submissionAttempts[identifier] = attempt
        }
        for barrier in drainBarriers {
            actions.append(.complete(barrier, .success([])))
        }
        drainBarriers.removeAll(keepingCapacity: true)
        self.generation = generation
        nextSequenceNumber = 1
        counters = Counters()
        isDraining = false
    }

    private func finishDrainIfPossibleLocked(actions: inout [UserAction]) {
        guard isDraining,
              readyJobs.isEmpty,
              window.unemittedCount == 0,
              !submissionAttempts.values.contains(where: {
                  $0.completionIsOpen
                      && isCurrentLocked($0.ready)
              }),
              activeInFlightCountLocked == 0 else {
            return
        }
        let barriers = drainBarriers
        drainBarriers.removeAll(keepingCapacity: true)
        for barrier in barriers {
            actions.append(.complete(barrier, .success([])))
        }
    }

    private func perform(_ actions: [UserAction]) {
        for action in actions { action.perform() }
    }

    private static func presentationFrames(
        for completed: InFlightJob
    ) -> [VideoPresentationFrame] {
        let normalized = completed.ready.job.current
        return [completed.outputs.first, completed.outputs.second].enumerated().map {
            index, output in
            VideoPresentationFrame(
                storage: .pixelBuffer(output),
                presentationTimeStamp: index == 0
                    ? normalized.presentationTimeStamp
                    : CMTimeAdd(normalized.presentationTimeStamp, normalized.fieldDuration),
                duration: normalized.fieldDuration,
                generation: normalized.frame.generation,
                sequenceNumber: completed.ready.firstSequenceNumber + UInt64(index),
                sourceAccessUnitID: normalized.frame.accessUnitID,
                formatMetadata: normalized.frame.formatMetadata
            )
        }
    }

    private static func playbackFailure(for failure: YADIFFailure) -> PlaybackFailure {
        switch failure {
        case .commandBufferAllocationFailed, .commandFailed:
            return commandFailure
        default:
            return textureFailure
        }
    }

    private static let invalidTimingFailure = PlaybackFailure(
        code: "video.timing",
        userMessage: "视频时间戳无效，请尝试其他频道。"
    )
    private static let textureFailure = PlaybackFailure(
        code: "video.texture",
        userMessage: "视频纹理处理失败，请稍后重试。"
    )
    private static let commandFailure = PlaybackFailure(
        code: "metal.command",
        userMessage: "视频渲染失败，请稍后重试。"
    )
}
