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
    private let lock = NSLock()
    private var storedWriter: SegmentedFMP4Writer
    private var cancelled = false
    private var physicalCount = 1

    init(configuration: SourceAACWriterConfiguration, boundary: SegmentBoundaryCoordinator,
         writerFactory: @escaping WriterFactory) throws {
        self.configuration = configuration; self.boundary = boundary; factory = writerFactory
        let writer = try writerFactory(configuration, nil)
        guard writer.binding == configuration.authority.initialBinding,
              writer.sourceAACConfiguration?.authority === configuration.authority,
              writer.sourceAACTerminalBinding != nil,
              writer.aacTerminalBinding == nil else { throw SourceAACFailure.writerBindingMismatch }
        storedWriter = writer
        do {
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

    func append(_ timed: HLSTimedAudioAccessUnit) async throws {
        guard lock.withLock({ !cancelled }) else { throw CancellationError() }
        let current = writer
        let unit = try SourceAACAccessUnit(timed: timed, configuration: configuration, binding: current.binding)
        do { try await current.appendSourceAACAwaitingReadiness(unit, boundary: boundary) }
        catch SegmentedFMP4WriterFailure.rolloverRequired {
            // The failed preflight has not claimed this source AU. Finish only
            // the physical window and retry the same producer proof once.
            let continuation = try await current.finishWriterWindow()
            guard lock.withLock({ !cancelled }), configuration.validates(timed) else { throw CancellationError() }
            let successor = try factory(configuration, continuation)
            do {
                guard successor.sourceAACTerminalBinding === current.sourceAACTerminalBinding,
                      successor.sourceAACConfiguration?.authority === configuration.authority else {
                    throw SourceAACFailure.writerBindingMismatch
                }
                try lock.withLock {
                    guard !cancelled, storedWriter === current else { throw CancellationError() }
                    storedWriter = successor; physicalCount += 1
                }
                try successor.start(at: configuration.firstPresentationTime.cmTime)
                let retry = try SourceAACAccessUnit(timed: timed, configuration: configuration, binding: successor.binding)
                try await successor.appendSourceAACAwaitingReadiness(retry, boundary: boundary)
            } catch { _ = await successor.cancelAwaitingCompletion(); throw error }
        }
    }
    func finish() async throws -> SourceAACFinalSeal {
        guard lock.withLock({ !cancelled }) else { throw CancellationError() }
        return try await writer.finishSourceAAC()
    }
    func cancel() {
        let current = lock.withLock { cancelled = true; return storedWriter }
        current.requestCancellation()
    }
    func cancelAndAwait() async {
        cancel()
        _ = await writer.cancelAwaitingCompletion()
    }
}
