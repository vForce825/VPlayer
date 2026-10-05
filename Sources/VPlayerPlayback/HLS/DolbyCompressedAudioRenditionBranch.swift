// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

enum DolbyInitialWriterRejection: Error, Sendable, Equatable {
    case candidateMismatch
    case cannotAddFormat
}

enum DolbyCompressedAudioRenditionFailure: Error, Sendable, Equatable {
    case initialWriterUnsupported(DolbyInitialWriterRejection)
    case sourceMismatch
    case partialAccessUnit
    case busy
    case cancelled
    case noWriter
    case invalidSuccessor
    case formatChanged
}

/// One logical rendition, with one physical writer in the normal stable epoch.
/// The owner invokes one append at a time; cancellation may arrive concurrently.
final class DolbyCompressedAudioRenditionBranch: @unchecked Sendable {
    typealias InitialFormatAdmission = @Sendable (
        CompressedAudioFormatConfiguration, SystemCompressedAudioFormat, AudioChannelLayout
    ) -> Bool
    /// Returns a constructed, idle writer. The branch starts and reuses it.
    typealias WriterFactory = @Sendable (
        CompressedAudioFormatConfiguration, CMAudioFormatDescription, WriterWindowContinuation?
    ) throws -> SegmentedFMP4Writer

    private let producer: DolbyAudioSourceProducer
    private let authorization: CompressedAudioCandidatePlanAuthorization
    private let boundary: SegmentBoundaryCoordinator
    private let initialFormatAdmission: InitialFormatAdmission
    private let writerFactory: WriterFactory
    private let fixedCharge: HLSCompressedAudioApplicationReservation
    private let capacityWakeup: WriterCapacityWakeup
    private let directBuilder: AC3DirectAccessUnitBuilder?
    private let aggregateBuilder: EAC3AccessUnitAssembler?
    // All mutable state is accessed through the producer's single control lane.
    private var storedWriter: SegmentedFMP4Writer?
    private var storedConfiguration: CompressedAudioFormatConfiguration?
    private var storedFormatDescription: CMAudioFormatDescription?
    private var storedSourceLayout: AudioChannelLayout?
    private var pending: [HLSTimedAudioAccessUnit] = []
    private var pendingBlocks = 0
    private var aggregateReservation: HLSAudioCopyTail?
    private var timelineIdentity: UUID?
    private var origin: MediaOriginReceipt?
    private var nextRawPTS: CMTime?
    private var lastConsumedID: UInt64?
    private var operationActive = false
    private var stopped = false
    private var storedPhysicalWriterCount = 0
    private var storedTerminal: SegmentedFMP4WriterTerminalReceipt?
    private var operationWaiter: CheckedContinuation<Void, Never>?
    private var cancellationTask: Task<Void, Never>?

    init(producer: DolbyAudioSourceProducer, authorization: CompressedAudioCandidatePlanAuthorization,
         boundary: SegmentBoundaryCoordinator, initialFormatAdmission: @escaping InitialFormatAdmission,
         writerFactory: @escaping WriterFactory) throws {
        guard producer.coordinator.acceptsCompressedAuthorization(authorization),
              authorization.codec == producer.source.codec,
              authorization.timelinePlan.sharedControlExecutor === producer.sharedControlExecutor else {
            throw DolbyCompressedAudioRenditionFailure.sourceMismatch
        }
        fixedCharge = try producer.reserveBranchStorage()
        capacityWakeup = try producer.makeCapacityWakeup()
        self.producer = producer; self.authorization = authorization; self.boundary = boundary
        self.initialFormatAdmission = initialFormatAdmission; self.writerFactory = writerFactory
        directBuilder = authorization.codec == .ac3
            ? try AC3DirectAccessUnitBuilder(coordinator: producer.coordinator, authorization: authorization) : nil
        aggregateBuilder = authorization.codec == .eac3
            ? EAC3AccessUnitAssembler(coordinator: producer.coordinator, authorization: authorization,
                allocator: producer.allocator) : nil
        pending.reserveCapacity(6)
    }

    var writer: SegmentedFMP4Writer? { producer.sharedControlExecutor.sync { storedWriter } }
    var configuration: CompressedAudioFormatConfiguration? { producer.sharedControlExecutor.sync { storedConfiguration } }
    var formatDescription: CMAudioFormatDescription? { producer.sharedControlExecutor.sync { storedFormatDescription } }
    var physicalWriterCount: Int { producer.sharedControlExecutor.sync { storedPhysicalWriterCount } }

    func append(_ timed: HLSTimedAudioAccessUnit) async throws {
        try beginOperation()
        defer { endOperation() }
        var completed: CompressedAudioAccessUnit?
        do {
            let members = try producer.sharedControlExecutor.sync { try collect(timed) }
            guard !members.isEmpty else { return }
            let first = members[0]
            guard let firstProof = first.source.dolbyProof else {
                throw DolbyCompressedAudioRenditionFailure.sourceMismatch
            }
            // canAdd and candidate rejection are reversible only here. No service
            // record, transfer, boundary, or native append has been created yet.
            try await installFirstWriterIfNeeded(first: first, proof: firstProof)
            let unit = try producer.sharedControlExecutor.sync { try assemble(members) }
            completed = unit
            let lifetime: DolbyAudioPayloadLifetime
            if unit.codec == .eac3 {
                guard let reservation = producer.sharedControlExecutor.sync({ aggregateReservation }) else {
                    throw DolbyCompressedAudioRenditionFailure.sourceMismatch
                }
                lifetime = try DolbyAudioPayloadLifetime.aggregate(bytes: unit.payload, reservation: reservation,
                    members: members.compactMap { $0.source.dolbyProof })
            } else {
                lifetime = firstProof.payloadLifetime
            }
            try producer.beginOutput()
            try await appendComplete(unit, timed: first, nativeTail: lifetime)
            try producer.sharedControlExecutor.sync {
                try requireCurrent()
                guard members.allSatisfy({ $0.validatesSourceMapping() }),
                      let last = members.last else { throw DolbyCompressedAudioRenditionFailure.sourceMismatch }
                // FreeBlock still owns the claimed lease and paid byte tail. Mark
                // each service record retired now; last native release removes it.
                for member in members {
                    guard let proof = member.source.dolbyProof, let admitted = proof.admittedProof,
                          producer.coordinator.retireAdmittedProof(admitted) else {
                        throw DolbyCompressedAudioRenditionFailure.sourceMismatch
                    }
                    proof.forgetRetiredAdmission()
                }
                lastConsumedID = last.source.id
                nextRawPTS = unit.presentationEnd
                pending.removeAll(keepingCapacity: true); pendingBlocks = 0; aggregateReservation = nil
            }
        } catch {
            let isInitialRejection: Bool
            if case DolbyCompressedAudioRenditionFailure.initialWriterUnsupported = error { isInitialRejection = true }
            else { isInitialRejection = false }
            // Joining native completion precedes disposing a possibly claimed AU.
            if let writer { _ = await writer.cancelAwaitingCompletion() }
            producer.sharedControlExecutor.sync {
                stopped = true
                if let completed { releaseUnclaimedCompleted(completed) }
                aggregateBuilder?.terminate(.cancelled)
                retirePending()
                if !isInitialRejection { producer.invalidateSourceInput() }
            }
            throw error
        }
    }

    private func collect(_ timed: HLSTimedAudioAccessUnit) throws -> [HLSTimedAudioAccessUnit] {
        try requireCurrent()
        guard timed.validatesSourceMapping(), let proof = timed.source.dolbyProof,
              proof.sourceIdentity == producer.identity, proof.isCurrent,
              timed.sourceOriginReceipt == authorization.timelinePlan.originReceipt,
              let issuer = timed.sourceTimelineIdentity,
              timelineIdentity == nil || timelineIdentity == issuer,
              origin == nil || origin == timed.sourceOriginReceipt,
              pending.count < 6 else { throw DolbyCompressedAudioRenditionFailure.sourceMismatch }
        if let configuration = storedConfiguration, configuration != proof.configuration {
            throw DolbyCompressedAudioRenditionFailure.formatChanged
        }
        let expected = pending.last.map { CMTimeAdd($0.source.presentationTimeStamp, $0.source.duration) }
            ?? nextRawPTS ?? authorization.firstAuthorizedAccessUnitStart
        guard CMTimeCompare(timed.source.presentationTimeStamp, expected) == 0 else {
            throw DolbyCompressedAudioRenditionFailure.sourceMismatch
        }
        if let previous = pending.first?.source.dolbyProof,
           previous.configuration != proof.configuration || previous.sourceLayout != proof.sourceLayout {
            throw DolbyCompressedAudioRenditionFailure.formatChanged
        }
        let blocks: Int
        if proof.configuration.codec == .eac3 {
            let header = try EAC3FrameInspector.inspect(proof.inputUnit.bytes)
            blocks = header.blockCount
            guard (pending.isEmpty ? (blocks == 6 || header.convsync == true) : header.convsync == false),
                  pendingBlocks + blocks <= 6 else { throw DolbyCompressedAudioRenditionFailure.partialAccessUnit }
            if pending.isEmpty { aggregateReservation = try producer.reserveAggregateCopy() }
        } else {
            blocks = 6
            guard pending.isEmpty, proof.codecFacts.sampleCount == 1_536 else {
                throw DolbyCompressedAudioRenditionFailure.sourceMismatch
            }
        }
        timelineIdentity = issuer; origin = timed.sourceOriginReceipt
        pending.append(timed); pendingBlocks += blocks
        return pendingBlocks == 6 ? pending : []
    }

    private func installFirstWriterIfNeeded(first: HLSTimedAudioAccessUnit, proof: DolbyAudioFrameProof) async throws {
        if writer != nil { return }
        guard initialFormatAdmission(proof.configuration, proof.systemFormat, proof.sourceLayout) else {
            throw DolbyCompressedAudioRenditionFailure.initialWriterUnsupported(.candidateMismatch)
        }
        let description = try AudioFormatDescriptionBuilder.make(proof.systemFormat).description
        guard try CompressedAudioChannelPositions.bitmap(in: description)
                == CompressedAudioChannelPositions.bitmap(from: proof.sourceLayout) else {
            throw DolbyCompressedAudioRenditionFailure.initialWriterUnsupported(.candidateMismatch)
        }
        let trial: SegmentedFMP4Writer
        do { trial = try writerFactory(proof.configuration, description, nil) }
        catch SegmentedFMP4WriterFailure.unsupportedCompressedAudioFormat {
            throw DolbyCompressedAudioRenditionFailure.initialWriterUnsupported(.cannotAddFormat)
        }
        do {
            try producer.sharedControlExecutor.sync {
                try requireCurrent()
                guard trial.binding == producer.binding else { throw DolbyCompressedAudioRenditionFailure.invalidSuccessor }
                guard first.timing.presentationTimeStamp == authorization.timelinePlan.originReceipt.effectiveStart else {
                    throw DolbyCompressedAudioRenditionFailure.sourceMismatch
                }
                try boundary.registerAudioRendition(producer.binding.renditionIdentity,
                    accessUnit: proof.configuration.codec == .ac3 ? .ac3(sampleRate: proof.codecFacts.sampleRate)
                        : .eac3Aggregated(sampleRate: proof.codecFacts.sampleRate, sampleCount: 1_536),
                    firstEffectiveStart: first.timing.presentationTimeStamp.cmTime)
                storedWriter = trial; storedConfiguration = proof.configuration
                storedFormatDescription = description; storedSourceLayout = proof.sourceLayout
                storedPhysicalWriterCount = 1
            }
            try trial.installCompressedCapacityWakeup(capacityWakeup)
            try trial.start(at: first.timing.presentationTimeStamp.cmTime)
        } catch {
            _ = await trial.cancelAwaitingCompletion()
            throw error
        }
    }

    private func assemble(_ members: [HLSTimedAudioAccessUnit]) throws -> CompressedAudioAccessUnit {
        try requireCurrent()
        var result: CompressedAudioAccessUnit?
        for timed in members {
            guard timed.validatesSourceMapping(), let proof = timed.source.dolbyProof else {
                throw DolbyCompressedAudioRenditionFailure.sourceMismatch
            }
            let admitted = try producer.admitForOutput(proof)
            guard try producer.coordinator.registerEligibleCompressedPlan(authorization, for: admitted),
                  let lease = try producer.coordinator.issueAudioServiceBranchLease(for: admitted,
                    admission: authorization.admissionIdentity) else {
                throw DolbyCompressedAudioRenditionFailure.sourceMismatch
            }
            if let directBuilder {
                result = try directBuilder.makeAccessUnit(inputUnit: proof.inputUnit, admittedProof: admitted,
                    directLease: lease, bundleNonce: .init(rawValue: try producer.allocator.next(in: .nonce)))
            } else if let aggregateBuilder {
                result = try aggregateBuilder.append(inputUnit: proof.inputUnit, admittedProof: admitted, aggregationLease: lease)
            }
        }
        guard let result, result.formatConfiguration == storedConfiguration else {
            throw DolbyCompressedAudioRenditionFailure.partialAccessUnit
        }
        return result
    }

    private func appendComplete(_ unit: CompressedAudioAccessUnit, timed: HLSTimedAudioAccessUnit,
                                nativeTail: DolbyAudioPayloadLifetime) async throws {
        var current = writer
        guard current != nil else { throw DolbyCompressedAudioRenditionFailure.noWriter }
        do {
            try await appendWhenCapacityReturns(unit, timed: timed, writer: current!, nativeTail: nativeTail)
        } catch SegmentedFMP4WriterFailure.rolloverRequired {
            // An actual pre-claim capacity boundary is the only continuation path.
            // Keep this very same complete AU and native tail throughout the retry.
            let continuation = try await current!.finishWriterWindow()
            let previous = current!.binding
            try producer.sharedControlExecutor.sync { try requireCurrent() }
            guard timed.validatesSourceMapping(), let configuration, let formatDescription else {
                throw DolbyCompressedAudioRenditionFailure.sourceMismatch
            }
            let successor = try writerFactory(configuration, formatDescription, continuation)
            do {
                try producer.sharedControlExecutor.sync {
                    try requireCurrent()
                    let next = successor.binding
                    guard continuation.predecessorTerminal.binding == previous,
                          previous.outputLifecycleEpoch == next.outputLifecycleEpoch,
                          previous.itemGeneration == next.itemGeneration, previous.mediaEpoch == next.mediaEpoch,
                          previous.publicationParticipantID == next.publicationParticipantID,
                          previous.renditionIdentity == next.renditionIdentity,
                          previous.writerIdentity != next.writerIdentity else {
                        throw DolbyCompressedAudioRenditionFailure.invalidSuccessor
                    }
                    storedWriter = successor; storedPhysicalWriterCount += 1
                }
                current = nil
                try successor.installCompressedCapacityWakeup(capacityWakeup)
                try successor.start(at: timed.timing.presentationTimeStamp.cmTime)
                try await appendWhenCapacityReturns(unit, timed: timed, writer: successor, nativeTail: nativeTail)
            } catch {
                _ = await successor.cancelAwaitingCompletion()
                throw error
            }
        }
    }

    private func appendWhenCapacityReturns(_ unit: CompressedAudioAccessUnit,
                                           timed: HLSTimedAudioAccessUnit,
                                           writer: SegmentedFMP4Writer,
                                           nativeTail: DolbyAudioPayloadLifetime) async throws {
        let deadline = try capacityWakeup.makeDeadline()
        while true {
            try Task.checkCancellation()
            try producer.sharedControlExecutor.sync { try requireCurrent() }
            guard timed.validatesSourceMapping() else { throw DolbyCompressedAudioRenditionFailure.sourceMismatch }
            let revision = capacityWakeup.currentRevision
            do {
                try await writer.appendMappedCompressedAwaitingReadiness(unit.writerSubmission,
                    timed: timed, coordinator: producer.coordinator, boundary: boundary, nativeTail: nativeTail)
                return
            } catch let error as SegmentedFMP4WriterFailure
                where error == .terminalOwnershipCapacityExceeded || error == .relayCapacityExceeded {
                guard try await capacityWakeup.wait(after: revision, until: deadline) else { throw error }
            }
        }
    }

    func validateInitialization(_ bytes: Data) throws -> DolbyWriterInitializationEvidence {
        try producer.sharedControlExecutor.sync {
            try requireCurrent()
            guard let storedConfiguration, let storedSourceLayout else { throw DolbyCompressedAudioRenditionFailure.noWriter }
            return try DolbyWriterInitializationEvidence.validate(bytes,
                configuration: storedConfiguration, sourceLayout: storedSourceLayout)
        }
    }

    func finish() async throws -> SegmentedFMP4WriterTerminalReceipt {
        if let receipt = producer.sharedControlExecutor.sync({ storedTerminal }) { return receipt }
        try beginOperation()
        defer { endOperation() }
        let current: SegmentedFMP4Writer = try producer.sharedControlExecutor.sync {
            try requireCurrent()
            guard pending.isEmpty else { throw DolbyCompressedAudioRenditionFailure.partialAccessUnit }
            guard let lastConsumedID, let storedWriter else { throw DolbyCompressedAudioRenditionFailure.noWriter }
            try producer.requireSourceDrained(throughFrameID: lastConsumedID)
            return storedWriter
        }
        let receipt = try await current.finish()
        return try producer.sharedControlExecutor.sync {
            try requireCurrent()
            guard let lastConsumedID, receipt.terminalReason == .finished else {
                throw DolbyCompressedAudioRenditionFailure.sourceMismatch
            }
            try producer.requireSourceDrained(throughFrameID: lastConsumedID)
            storedTerminal = receipt; stopped = true
            return receipt
        }
    }

    func cancel() {
        capacityWakeup.cancel()
        let current: SegmentedFMP4Writer? = producer.sharedControlExecutor.sync {
            stopped = true; producer.cancel()
            if !operationActive { aggregateBuilder?.terminate(.cancelled); retirePending() }
            return storedWriter
        }
        _ = current?.cancel()
    }

    func cancelAndAwait() async {
        cancel()
        let task: Task<Void, Never> = producer.sharedControlExecutor.sync {
            if let cancellationTask { return cancellationTask }
            let task = Task { [self] in
                if let writer { _ = await writer.cancelAwaitingCompletion() }
                await withCheckedContinuation { continuation in
                    producer.sharedControlExecutor.sync {
                        if operationActive { operationWaiter = continuation }
                        else { continuation.resume() }
                    }
                }
                producer.sharedControlExecutor.sync {
                    aggregateBuilder?.terminate(.cancelled); retirePending()
                }
            }
            cancellationTask = task
            return task
        }
        await task.value
        producer.sharedControlExecutor.sync { cancellationTask = nil }
    }

    private func beginOperation() throws {
        try producer.sharedControlExecutor.sync {
            try requireCurrent()
            guard !operationActive else { throw DolbyCompressedAudioRenditionFailure.busy }
            operationActive = true
        }
    }
    private func endOperation() {
        let waiter = producer.sharedControlExecutor.sync {
            operationActive = false
            let waiter = operationWaiter; operationWaiter = nil
            return waiter
        }
        waiter?.resume()
    }
    private func requireCurrent() throws {
        guard !stopped, !Task.isCancelled, producer.isCurrent,
              producer.coordinator.acceptsCompressedAuthorization(authorization) else {
            throw DolbyCompressedAudioRenditionFailure.cancelled
        }
    }
    private func retirePending() {
        for member in pending {
            guard let proof = member.source.dolbyProof, let admitted = proof.admittedProof else { continue }
            if producer.coordinator.retireAdmittedProof(admitted) { proof.forgetRetiredAdmission() }
        }
        pending.removeAll(keepingCapacity: true); pendingBlocks = 0; aggregateReservation = nil
    }
    private func releaseUnclaimedCompleted(_ unit: CompressedAudioAccessUnit) {
        // Native cancellation/append has been joined, but a retained backing alias
        // may outlive both. Never release a writer-claimed lease here: FreeBlock
        // remains its only last-use authority, independently of paid byte tails.
        let owner: AudioServiceBranchTransferOwnerIdentity
        let identities: [AudioServiceBranchLeaseIdentity]
        if let bundle = unit.directBundleIdentity, let lease = unit.directLeaseIdentity {
            owner = .compressedAccessUnit(bundle); identities = [lease]
        } else if let bundle = unit.eac3BundleIdentity, let aggregation = unit.aggregationProof {
            owner = .eac3AccessUnit(bundle); identities = aggregation.orderedAggregationLeaseIdentities.values
        } else { return }
        for identity in identities {
            let mayRelease = producer.coordinator.withAudioServiceCAS {
                pending.contains { member in
                    guard let admitted = member.source.dolbyProof?.admittedProof,
                          let participation = admitted.branchState.participations.first(where: {
                              $0.lease?.identity == identity
                          }), let lease = participation.lease else { return false }
                    return !lease.writerClaimed
                }
            }
            if mayRelease {
                _ = producer.coordinator.releaseAudioServiceBranchLease(identity, expectedOwner: owner)
            }
        }
    }
}
