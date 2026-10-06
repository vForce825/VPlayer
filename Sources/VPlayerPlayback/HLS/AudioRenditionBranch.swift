// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 单个 AAC rendition 的真实增量接线。一个 branch 在整个流期只持有同一个
/// encoder/converter 与至多当前一个物理 writer；跨 window 时同一 branch 是唯一 owner。
final class AudioRenditionBranch: @unchecked Sendable {
    /// 不新增总 cap：准入直接使用 AAC workspace 既有 packet cap；encoder 会在
    /// 此上限内按实际 pending 与 maximumPacket 再取得可拆分 reservation。
    static let maximumPumpOutputBytes = AACRenditionEncoder.maximumSignedPumpAllocationBytes
    static let maximumEmissionsPerPump = 32

    private let encoder: AACRenditionEncoder
    private let writerHeadroomConfigured: Bool
    typealias WriterWindowFactory = @Sendable (
        AACWriterWindowContinuation
    ) throws -> SegmentedFMP4Writer

    private var writer: SegmentedFMP4Writer
    private let writerWindowFactory: WriterWindowFactory?
    private let coordinator: SegmentBoundaryCoordinator
    private let admission: HLSDataPlaneAdmission
    private let lock = NSLock()
    private let runner = NSLock()
    private var ended = false
    private var storedWriterReceipt: AACIncrementalWriterReceipt?
    private var storedFinalReceipt: AACEncoderFinalReceipt?
    private var maximumBufferedEmissions = 0
    private var pending: PendingBatch?
    private var storedFirstCommittedEmissionIdentity: AACIncrementalEmissionIdentity?
    private var storedLastCommittedEmissionIdentity: AACIncrementalEmissionIdentity?
    private var physicalWriterCount = 1
    private var rolloverInProgress = false
    private var asyncRunnerActive = false
    private var candidateTicket: AudioOnlyCandidateTicket?
    private var drainFences: CandidateBranchDrainFences?

    struct PendingMemoryUsage: Sendable, Equatable {
        let reservedBytes: Int
        let actualFrozenAndMaterializedBytes: Int
    }

    private final class PendingBatch {
        var emissions: [AACIncrementalEmission?]
        let result: AACStreamPumpResult
        let lease: HLSDataPlaneAdmission.Lease
        var nextIndex = 0

        init(emissions: [AACIncrementalEmission], result: AACStreamPumpResult,
             lease: HLSDataPlaneAdmission.Lease) {
            self.emissions = emissions.map(Optional.some)
            self.result = result
            self.lease = lease
        }
    }

    init(
        encoder: AACRenditionEncoder,
        writer: SegmentedFMP4Writer,
        coordinator: SegmentBoundaryCoordinator,
        writerWindowFactory: WriterWindowFactory? = nil,
        admission: HLSDataPlaneAdmission = .init(
            capacity: 1,
            maximumBytes: AudioRenditionBranch.maximumPumpOutputBytes)
    ) {
        self.encoder = encoder
        writerHeadroomConfigured = encoder.configureWriterBoundary(maximumDuration: coordinator.session.maximumBoundaryDuration)
        self.writer = writer
        self.writerWindowFactory = writerWindowFactory
        self.coordinator = coordinator
        self.admission = admission
    }

    var writerAdmissionSnapshot: AACWriterAdmissionSnapshot? { encoder.writerAdmissionSnapshot }
    var writerUsage: SegmentedFMP4WriterUsage { lock.withLock { writer }.usage }

    var writerReceipt: AACIncrementalWriterReceipt? {
        lock.withLock { storedWriterReceipt }
    }

    var renditionTerminalBinding: AACRenditionTerminalBinding {
        lock.withLock { writer.aacRenditionTerminalBinding! }
    }

    var bufferedEmissionHighWatermark: Int {
        lock.withLock { maximumBufferedEmissions }
    }

    var physicalWriterWindowCount: Int { lock.withLock { physicalWriterCount } }
    var aacCallbackMembershipSnapshot: AACMediaMembershipSnapshot? {
        lock.withLock { writer.aacCallbackMembershipSnapshot }
    }

    var pendingEmissionIdentity: AACIncrementalEmissionIdentity? {
        lock.withLock {
            guard let pending, pending.nextIndex < pending.emissions.count else { return nil }
            return pending.emissions[pending.nextIndex].map(AACIncrementalEmissionIdentity.init)
        }
    }

    var lastCommittedEmissionIdentity: AACIncrementalEmissionIdentity? {
        lock.withLock { storedLastCommittedEmissionIdentity }
    }

    var firstCommittedEmissionIdentity: AACIncrementalEmissionIdentity? {
        lock.withLock { storedFirstCommittedEmissionIdentity }
    }

    var pendingMemoryUsage: PendingMemoryUsage? {
        lock.withLock {
            guard let pending else { return nil }
            return PendingMemoryUsage(
                reservedBytes: pending.lease.bytes,
                actualFrozenAndMaterializedBytes:
                    pending.emissions.reduce(0) { $0 + ($1?.accountedFrozenBytes ?? 0) })
        }
    }

    func pump(_ input: AACStreamPumpInput) throws -> AACStreamPumpResult {
        try runner.withLock {
            guard lock.withLock({ !asyncRunnerActive && !rolloverInProgress }) else {
                throw AACRenditionFailure.busy
            }
            try collectPumpIsolated(input)
            return try flushPendingIsolated()
        }
    }

    private func collectPumpIsolated(_ input: AACStreamPumpInput) throws {
        guard writerHeadroomConfigured else { throw AACRenditionFailure.capacityExceeded }
        guard lock.withLock({ !ended }) else {
            throw AACRenditionFailure.invalidInput
        }
        guard lock.withLock({ pending == nil }) else {
            throw AACRenditionFailure.busy
        }
        guard let pumpLease = admission.waitForAdmission(
            bytes: Self.maximumPumpOutputBytes) else {
            throw AACRenditionFailure.cancelled
        }

        var emissions: [AACIncrementalEmission] = []
        emissions.reserveCapacity(Self.maximumEmissionsPerPump)
        let result: AACStreamPumpResult
        do {
            result = try encoder.pumpSigned(input) { emission in
                guard emissions.count < Self.maximumEmissionsPerPump else {
                    throw AACRenditionFailure.capacityExceeded
                }
                emissions.append(emission)
            }
        } catch {
            pumpLease.release()
            throw error
        }
        lock.withLock {
            maximumBufferedEmissions = max(maximumBufferedEmissions, emissions.count)
            pending = PendingBatch(emissions: emissions, result: result,
                                   lease: pumpLease)
        }
    }

    /// runner 只覆盖 converter 的同步操作；native append 等待期间用状态门保持单入口。
    func pumpAwaitingWriter(_ input: AACStreamPumpInput) async throws -> AACStreamPumpResult {
        try claimAsyncRunner()
        defer { endAsyncRunner() }
        try runner.withLock { try collectPumpIsolated(input) }
        return try await flushPendingAwaitingWriter()
    }

    func retryPendingAwaitingWriter() async throws -> AACStreamPumpResult? {
        try claimAsyncRunner()
        defer { endAsyncRunner() }
        guard lock.withLock({ pending != nil }) else { return nil }
        return try await flushPendingAwaitingWriter()
    }

    private func claimAsyncRunner() throws {
        try runner.withLock {
            try lock.withLock {
                guard !ended, !asyncRunnerActive, !rolloverInProgress else {
                    throw AACRenditionFailure.busy
                }
                asyncRunnerActive = true
            }
        }
    }

    private func endAsyncRunner() {
        let retiring = lock.withLock { () -> PendingBatch? in
            asyncRunnerActive = false
            guard ended else { return nil }
            defer { pending = nil }
            return pending
        }
        retiring?.lease.release()
    }

    var isWriterWindowRolloverPending: Bool {
        lock.withLock { writer.isAACWriterWindowRolloverPending }
    }

    func retryPending() throws -> AACStreamPumpResult? {
        runner.lock()
        defer { runner.unlock() }
        guard lock.withLock({ !asyncRunnerActive && !rolloverInProgress }) else {
            throw AACRenditionFailure.busy
        }
        guard lock.withLock({ pending != nil }) else { return nil }
        return try flushPendingIsolated()
    }

    /// rollover 只处理 writer 明确签出的共同边界请求；普通 not-ready 仍保留为
    /// `waitingForWriter`，不得伪装成新物理 writer 或重新 Fill。
    func retryPendingAcrossWriterWindow() async throws -> AACStreamPumpResult? {
        var createdWriter: SegmentedFMP4Writer?
        let oldWriter: SegmentedFMP4Writer = try lock.withLock {
            guard pending != nil, !ended, !rolloverInProgress, !asyncRunnerActive,
                  writer.isAACWriterWindowRolloverPending,
                  writerWindowFactory != nil else {
                throw AACRenditionFailure.busy
            }
            rolloverInProgress = true
            return writer
        }
        do {
            let continuation = try await oldWriter.finishAACWriterWindow()
            guard let writerWindowFactory else {
                throw AACRenditionFailure.invalidInput
            }
            let nextWriter = try writerWindowFactory(continuation)
            createdWriter = nextWriter
            try nextWriter.start(at: .zero)
            return try runner.withLock {
                try lock.withLock {
                    guard writer === oldWriter, pending != nil, !ended else {
                        throw AACRenditionFailure.cancelled
                    }
                    writer = nextWriter
                    physicalWriterCount += 1
                    rolloverInProgress = false
                }
                return try flushPendingIsolated()
            }
        } catch {
            let retiring = lock.withLock { () -> PendingBatch? in
                rolloverInProgress = false
                ended = true
                defer { pending = nil }
                return pending
            }
            retiring?.lease.release()
            if let createdWriter, createdWriter !== oldWriter {
                _ = createdWriter.cancel()
            }
            throw error
        }
    }

    func retryPendingAcrossWriterWindowAwaitingWriter() async throws -> AACStreamPumpResult? {
        try claimAsyncRunner()
        defer { endAsyncRunner() }
        let oldWriter = try lock.withLock { () throws -> SegmentedFMP4Writer in
            guard pending != nil, writer.isAACWriterWindowRolloverPending,
                  writerWindowFactory != nil else { throw AACRenditionFailure.busy }
            rolloverInProgress = true
            return writer
        }
        var created: SegmentedFMP4Writer?
        do {
            let continuation = try await oldWriter.finishAACWriterWindow()
            try Task.checkCancellation()
            guard let writerWindowFactory else { throw AACRenditionFailure.invalidInput }
            let next = try writerWindowFactory(continuation)
            created = next
            try next.start(at: .zero)
            try lock.withLock {
                guard writer === oldWriter, pending != nil, !ended else {
                    throw AACRenditionFailure.cancelled
                }
                writer = next
                physicalWriterCount += 1
                rolloverInProgress = false
            }
            return try await flushPendingAwaitingWriter()
        } catch {
            let batch = lock.withLock { () -> PendingBatch? in
                rolloverInProgress = false
                ended = true
                defer { pending = nil }
                return pending
            }
            batch?.lease.release()
            if let created { _ = await created.cancelAwaitingCompletion() }
            throw error
        }
    }

    func finishRendition() async throws -> AACRenditionWriterFinalReceipt {
        let current = lock.withLock { writer }
        guard let final = lock.withLock({ storedFinalReceipt }) else {
            throw AACRenditionFailure.invalidInput
        }
        return try await current.finishAACRendition(final)
    }

    func finishFinalWriter() async throws -> SegmentedFMP4WriterTerminalReceipt {
        try await finishRendition().systemTerminal
    }

    private func flushPendingIsolated() throws -> AACStreamPumpResult {
        guard let batch = lock.withLock({ pending }) else {
            throw AACRenditionFailure.invalidInput
        }
        do {
            while batch.nextIndex < batch.emissions.count {
                guard let emission = lock.withLock({ batch.emissions[batch.nextIndex] }) else {
                    throw AACRenditionFailure.invalidInput
                }
                switch try writer.appendAACIncremental(
                    emission, coordinator: coordinator) {
                case .retryLater:
                    return AACStreamPumpResult(
                        needsInput: batch.result.needsInput,
                        summary: nil,
                        finalReceipt: nil,
                        waitingForWriter: true)
                case .appended:
                    lock.withLock {
                        // Drop only the consumed frozen owner. Native block aliases
                        // retain their own lease, and the pump lease covers the suffix.
                        batch.emissions[batch.nextIndex] = nil
                        batch.nextIndex += 1
                        let identity = AACIncrementalEmissionIdentity(emission)
                        if storedFirstCommittedEmissionIdentity == nil {
                            storedFirstCommittedEmissionIdentity = identity
                        }
                        storedLastCommittedEmissionIdentity = identity
                    }
                }
            }
            if let final = batch.result.finalReceipt {
                let receipt = try writer.sealAACIncrementalStream(final)
                lock.withLock {
                    precondition(storedWriterReceipt == nil,
                                 "AAC branch 终态只能封存一次")
                    storedWriterReceipt = receipt
                    storedFinalReceipt = final
                    ended = true
                }
            }
            lock.withLock {
                precondition(pending === batch, "pending batch 身份不可替换")
                pending = nil
            }
            batch.lease.release()
            return batch.result
        } catch SegmentedFMP4WriterFailure.rolloverRequired {
            return AACStreamPumpResult(
                needsInput: batch.result.needsInput,
                summary: nil,
                finalReceipt: nil,
                waitingForWriter: true,
                waitingForEncoderBudget: false)
        } catch {
            lock.withLock {
                if pending === batch { pending = nil }
                ended = true
            }
            batch.lease.release()
            throw error
        }
    }

    private func flushPendingAwaitingWriter() async throws -> AACStreamPumpResult {
        guard let batch = lock.withLock({ pending }) else { throw AACRenditionFailure.invalidInput }
        do {
            while true {
                let next = try lock.withLock { () throws -> (SegmentedFMP4Writer, AACIncrementalEmission)? in
                    guard !ended, pending === batch else { throw AACRenditionFailure.cancelled }
                    guard batch.nextIndex < batch.emissions.count else { return nil }
                    guard let emission = batch.emissions[batch.nextIndex] else {
                        throw AACRenditionFailure.invalidInput
                    }
                    return (writer, emission)
                }
                guard let (currentWriter, emission) = next else { break }
                let result = try await currentWriter.appendAACIncrementalAwaitingReadiness(
                    emission, coordinator: coordinator)
                guard result == .appended else { throw AACRenditionFailure.busy }
                try lock.withLock {
                    guard !ended, pending === batch else { throw AACRenditionFailure.cancelled }
                    batch.emissions[batch.nextIndex] = nil
                    batch.nextIndex += 1
                    let identity = AACIncrementalEmissionIdentity(emission)
                    if storedFirstCommittedEmissionIdentity == nil { storedFirstCommittedEmissionIdentity = identity }
                    storedLastCommittedEmissionIdentity = identity
                }
            }
            if let final = batch.result.finalReceipt {
                let current = lock.withLock { writer }
                let receipt = try current.sealAACIncrementalStream(final)
                try lock.withLock {
                    guard !ended, pending === batch else { throw AACRenditionFailure.cancelled }
                    precondition(storedWriterReceipt == nil, "AAC branch 终态只能封存一次")
                    storedWriterReceipt = receipt
                    storedFinalReceipt = final
                    ended = true
                }
            }
            lock.withLock { if pending === batch { pending = nil } }
            batch.lease.release()
            return batch.result
        } catch SegmentedFMP4WriterFailure.rolloverRequired {
            if lock.withLock({ ended }) {
                lock.withLock { if pending === batch { pending = nil } }
                batch.lease.release()
                throw AACRenditionFailure.cancelled
            }
            return AACStreamPumpResult(needsInput: batch.result.needsInput,
                summary: nil, finalReceipt: nil, waitingForWriter: true,
                waitingForEncoderBudget: false)
        } catch {
            lock.withLock {
                if pending === batch { pending = nil }
                ended = true
            }
            batch.lease.release()
            throw error
        }
    }

    func attachAudioOnlyCandidate(ticket: AudioOnlyCandidateTicket, fences: CandidateBranchDrainFences) {
        lock.withLock {
            candidateTicket = ticket
            drainFences = fences
        }
    }

    func cancel(semantic: AudioServiceSemanticCoordinator? = nil) {
        admission.cancel()
        let action = runner.withLock {
            lock.withLock { () -> (SegmentedFMP4Writer, PendingBatch?, CandidateBranchDrainFences?) in
                ended = true
                // 异步 flush 独占的 batch 由该任务在 native 返回后释放 reservation。
                let retiring = asyncRunnerActive ? nil : pending
                if !asyncRunnerActive { pending = nil }
                return (writer, retiring, drainFences)
            }
        }
        action.0.requestCancellation()
        action.1?.lease.release()
        _ = action.2?.retire(semantic: semantic)
    }

    func cancelAndAwait() async {
        cancel()
        let current = lock.withLock { writer }
        _ = await current.cancelAwaitingCompletion()
    }

}

struct AACIncrementalEmissionIdentity: Sendable, Hashable {
    let liveContextIdentity: UUID
    let ordinal: UInt64
    let evidenceDigest: Data

    init(_ emission: AACIncrementalEmission) {
        liveContextIdentity = emission.liveContextIdentity
        ordinal = emission.ordinal
        evidenceDigest = emission.evidenceDigest
    }
}
