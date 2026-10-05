// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// No decoder, PCM converter, calibrator or encoder is created in this branch.
/// The one graph runner serializes append/finish; cancellation may run concurrently.
final class SourceAACRenditionBranch: @unchecked Sendable {
    typealias WriterFactory = @Sendable (SourceAACWriterConfiguration, WriterWindowContinuation?) throws -> SegmentedFMP4Writer
    let configuration: SourceAACWriterConfiguration
    private let boundary: SegmentBoundaryCoordinator
    private let factory: WriterFactory
    private let capacityWakeup: WriterCapacityWakeup
    private let lock = NSLock()
    private var storedWriter: SegmentedFMP4Writer
    private var cancelled = false
    private var physicalCount = 1

    init(configuration: SourceAACWriterConfiguration, boundary: SegmentBoundaryCoordinator,
         writerFactory: @escaping WriterFactory) throws {
        self.configuration = configuration; self.boundary = boundary; factory = writerFactory
        capacityWakeup = try configuration.authority.makeCapacityWakeup()
        let writer = try writerFactory(configuration, nil)
        guard writer.binding == configuration.authority.initialBinding,
              writer.sourceAACConfiguration?.authority === configuration.authority,
              writer.sourceAACTerminalBinding != nil,
              writer.aacTerminalBinding == nil else { throw SourceAACFailure.writerBindingMismatch }
        storedWriter = writer
        do {
            try writer.installCompressedCapacityWakeup(capacityWakeup)
            try writer.start(at: configuration.firstPresentationTime.cmTime)
            try boundary.registerAudioRendition(writer.binding.renditionIdentity,
                accessUnit: .aac(sampleRate: configuration.sampleRate),
                firstPhysicalStart: configuration.firstPresentationTime.cmTime,
                firstEffectiveStart: configuration.firstPresentationTime.cmTime)
        } catch { _ = writer.cancel(); throw error }
    }
    var writer: SegmentedFMP4Writer { lock.withLock { storedWriter } }
    var physicalWriterCount: Int { lock.withLock { physicalCount } }
    var terminalBinding: SourceAACWriterTerminalBinding? { writer.sourceAACTerminalBinding }
#if DEBUG
    var isWaitingForCapacityForTesting: Bool { capacityWakeup.isWaitingForTesting }
#endif

    func append(_ timed: HLSTimedAudioAccessUnit) async throws {
        guard lock.withLock({ !cancelled }) else { throw CancellationError() }
        var current: SegmentedFMP4Writer? = writer
        let unit = try SourceAACAccessUnit(timed: timed, configuration: configuration, binding: current!.binding)
        do { try await appendWhenCapacityReturns(unit, using: current!) }
        catch SegmentedFMP4WriterFailure.rolloverRequired {
            // The failed preflight has not claimed this source AU. Finish only
            // the physical window and retry the same producer proof once.
            let continuation = try await current!.finishWriterWindow()
            let stableRoot = current!.sourceAACTerminalBinding
            guard lock.withLock({ !cancelled }), configuration.validates(timed) else { throw CancellationError() }
            let successor = try factory(configuration, continuation)
            do {
                guard successor.sourceAACTerminalBinding === stableRoot,
                      successor.sourceAACConfiguration?.authority === configuration.authority else {
                    throw SourceAACFailure.writerBindingMismatch
                }
                try lock.withLock {
                    guard !cancelled, storedWriter === current else { throw CancellationError() }
                    storedWriter = successor; physicalCount += 1
                }
                // A finished predecessor must not be pinned by this async frame
                // while its successor waits for the shared native alias gate.
                current = nil
                try successor.installCompressedCapacityWakeup(capacityWakeup)
                try successor.start(at: configuration.firstPresentationTime.cmTime)
                let retry = try SourceAACAccessUnit(timed: timed, configuration: configuration, binding: successor.binding)
                try await appendWhenCapacityReturns(retry, using: successor)
            } catch { _ = await successor.cancelAwaitingCompletion(); throw error }
        }
    }
    private func appendWhenCapacityReturns(_ unit: SourceAACAccessUnit,
                                           using writer: SegmentedFMP4Writer) async throws {
        let deadline = try capacityWakeup.makeDeadline()
        while true {
            try Task.checkCancellation()
            guard lock.withLock({ !cancelled }), unit.validates() else { throw CancellationError() }
            let revision = capacityWakeup.currentRevision
            do { try await writer.appendSourceAACAwaitingReadiness(unit, boundary: boundary); return }
            catch let error as SegmentedFMP4WriterFailure
                where error == .terminalOwnershipCapacityExceeded || error == .relayCapacityExceeded {
                // Release may precede waiter installation; revision closes that
                // race. No polling and no second physical-window attempt.
                guard try await capacityWakeup.wait(after: revision, until: deadline) else { throw error }
            }
        }
    }

    func finish() async throws -> SourceAACFinalSeal {
        guard lock.withLock({ !cancelled }) else { throw CancellationError() }
        return try await writer.finishSourceAAC()
    }
    func cancel() {
        let current = lock.withLock { cancelled = true; return storedWriter }
        capacityWakeup.cancel()
        current.requestCancellation()
    }
    func cancelAndAwait() async {
        cancel()
        _ = await writer.cancelAwaitingCompletion()
    }
}
