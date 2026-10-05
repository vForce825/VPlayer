// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CryptoKit
import Foundation
import Darwin

/// Immutable, callback-issued evidence. Construction requires the private writer
/// origin and successful actual-byte/sample verification on its callback lane.
final class SourceAACCallbackEvidence: @unchecked Sendable {
    let authorityIdentity: UUID
    let binding: FMP4WriterBinding
    let kind: SealedMediaObjectKind
    let logicalSequence: UInt64
    let writtenRange: FMP4PresentationRange?
    let timelineOffset: ExactMediaTime?
    let sampleCount: Int
    let sampleEntryDigest: Data
    private let digest: Data
    private let reportIdentity: UUID
    private let charge: HLSCompressedAudioApplicationReservation
    fileprivate init(origin: SourceAACWriterOrigin, kind: SealedMediaObjectKind, sequence: UInt64,
                     digest: Data, reportIdentity: UUID, range: FMP4PresentationRange?,
                     offset: ExactMediaTime?, sampleCount: Int, sampleEntryDigest: Data,
                     charge: HLSCompressedAudioApplicationReservation) {
        authorityIdentity = origin.authority.identity; binding = origin.binding
        self.kind = kind; logicalSequence = sequence; self.digest = digest
        self.reportIdentity = reportIdentity; writtenRange = range; timelineOffset = offset
        self.sampleCount = sampleCount; self.sampleEntryDigest = sampleEntryDigest; self.charge = charge
    }
    func matches(_ object: SealedMediaObject) -> Bool {
        object.publicationEvidence?.sourceAAC === self
            && object.publicationEvidence?.matches(object) == true
            && object.binding == binding && object.kind == kind && object.logicalSequence == logicalSequence
            && object.digest == digest && object.report.identity == reportIdentity
    }
}

struct SourceAACFinalSeal: Sendable {
    let authorityIdentity: UUID
    let terminal: SegmentedFMP4WriterTerminalReceipt
    let lastSourceID: UInt64
    let inputCount: UInt64
    let lastLogicalSequence: UInt64
    let timelineOffset: ExactMediaTime
    let writtenStart: ExactMediaTime
    let writtenEnd: ExactMediaTime
    let sampleEntryDigest: Data
    fileprivate init(authority: UUID, terminal: SegmentedFMP4WriterTerminalReceipt,
                     lastSourceID: UInt64, inputCount: UInt64, sequence: UInt64,
                     offset: ExactMediaTime, start: ExactMediaTime, end: ExactMediaTime, digest: Data) {
        authorityIdentity = authority; self.terminal = terminal; self.lastSourceID = lastSourceID
        self.inputCount = inputCount; lastLogicalSequence = sequence; timelineOffset = offset
        writtenStart = start; writtenEnd = end; sampleEntryDigest = digest
    }
}

/// Stable rendition state is bounded: one canonical init, current window scalars,
/// one last media receipt and final EOF. Old callback evidence travels with the
/// already-paid sealed object, never in a cumulative history retained here.
final class SourceAACWriterTerminalBinding: @unchecked Sendable {
    let configuration: SourceAACWriterConfiguration
    private let lock = NSLock()
    private let applicationLedger: HLSDeliveryApplicationChargeLedger
    private var initializationCharge: HLSCompressedAudioApplicationReservation?
    private var initialization: Data?
    private var sampleEntryDigest: Data?
    private var currentOrigin: UUID
    private var currentBinding: FMP4WriterBinding
    private var currentWindowInputCount = 0
    private var currentWindowCallbackCount = 0
    private var windowTerminal: SegmentedFMP4WriterTerminalReceipt?
    private var nextInput: ExactMediaTime
    private var lastSourceID: UInt64?
    private var inputCount: UInt64 = 0
    private var callbackSampleCount: UInt64 = 0
    private var lastCallbackSequence: UInt64?
    private var firstWritten: ExactMediaTime?
    private var nextWritten: ExactMediaTime?
    private var offset: ExactMediaTime?
    private var failed = false
    private var storedFinal: SourceAACFinalSeal?

    init(origin: SourceAACWriterOrigin, configuration: SourceAACWriterConfiguration,
         applicationLedger: HLSDeliveryApplicationChargeLedger) throws {
        guard origin.authority === configuration.authority,
              configuration.authority.acceptsInitialWriter(origin.binding) else { throw SourceAACFailure.writerBindingMismatch }
        self.configuration = configuration; self.applicationLedger = applicationLedger
        currentOrigin = origin.identity; currentBinding = origin.binding
        nextInput = configuration.firstPresentationTime
        try configuration.authority.installWriter(origin)
    }
    var finalSeal: SourceAACFinalSeal? { lock.withLock { failed ? nil : storedFinal } }
    var timelineOffset: ExactMediaTime? { lock.withLock { failed ? nil : offset } }
    var isCurrent: Bool { lock.withLock { !failed && configuration.authority.stream.isCurrent } }

    func beginWindow(origin: SourceAACWriterOrigin, predecessor: SegmentedFMP4WriterTerminalReceipt) throws {
        try lock.withLock {
            guard !failed, storedFinal == nil, windowTerminal == predecessor,
                  origin.authority === configuration.authority,
                  origin.predecessorBinding == currentBinding,
                  predecessor.terminalReason == .finished else { throw SourceAACFailure.writerBindingMismatch }
            try configuration.authority.installWriter(origin)
            currentOrigin = origin.identity; currentBinding = origin.binding
            currentWindowInputCount = 0; currentWindowCallbackCount = 0; windowTerminal = nil
        }
    }
    func acceptsInput(_ unit: SourceAACAccessUnit, origin: SourceAACWriterOrigin) -> Bool {
        lock.withLock {
            !failed && storedFinal == nil && windowTerminal == nil && currentOrigin == origin.identity
                && unit.binding == currentBinding && unit.configuration.authority === configuration.authority
                && unit.validates() && unit.presentationStart == nextInput
                && inputCount < UInt64.max && (lastSourceID.map { unit.sourceID > $0 } ?? true)
        }
    }
    func recordInput(_ unit: SourceAACAccessUnit, origin: SourceAACWriterOrigin) throws {
        try lock.withLock {
            guard !failed, windowTerminal == nil, currentOrigin == origin.identity,
                  unit.binding == currentBinding, unit.presentationStart == nextInput,
                  inputCount < UInt64.max else { throw SourceAACFailure.timelineMismatch }
            nextInput = try unit.presentationStart.adding(unit.duration)
            lastSourceID = unit.sourceID; inputCount += 1; currentWindowInputCount += 1
        }
    }
    func acceptCallback(origin: SourceAACWriterOrigin, kind: SealedMediaObjectKind,
                        sequence: UInt64, bytes: Data, report: SegmentReportReference,
                        samples: [WriterSegmentEvidence.Sample]) throws -> SourceAACCallbackEvidence {
        try lock.withLock {
            guard !failed, windowTerminal == nil, currentOrigin == origin.identity,
                  currentBinding == origin.binding, configuration.authority.stream.isCurrent else {
                throw SourceAACFailure.writerBindingMismatch
            }
            if kind == .initialization {
                let evidence = try SourceAACInitializationEvidence.validate(bytes, configuration: configuration)
                guard sampleEntryDigest == nil || sampleEntryDigest == evidence.sampleEntryDigest else {
                    throw CompressedAudioInitializationRejection.invalidConfiguration
                }
                if initialization == nil {
                    let charge = try HLSCompressedAudioApplicationReservation.reserve(bytes: 65_536,
                        ledger: applicationLedger)
                    initialization = bytes; initializationCharge = charge
                    sampleEntryDigest = evidence.sampleEntryDigest
                }
                let callbackCharge = try HLSCompressedAudioApplicationReservation.reserve(bytes: 2_048,
                    ledger: applicationLedger)
                return .init(origin: origin, kind: kind, sequence: sequence,
                    digest: Data(SHA256.hash(data: bytes)), reportIdentity: report.identity,
                    range: nil, offset: nil, sampleCount: 0, sampleEntryDigest: evidence.sampleEntryDigest,
                    charge: callbackCharge)
            }
            guard let initialization, let sampleEntryDigest, !samples.isEmpty, samples.count <= 320,
                  let duration = report.duration, let first = samples.first,
                  lastCallbackSequence.map({ $0 < UInt64.max && sequence == $0 + 1 }) ?? true else {
                throw SourceAACFailure.timelineMismatch
            }
            let parsed = try FMP4CompressedAudioInspection.sourceAACFragment(initialization: initialization,
                media: bytes, configuration: configuration, expectedDuration: ExactMediaTime(duration),
                applicationLedger: applicationLedger)
            guard parsed.sampleCount == samples.count else { throw SourceAACFailure.timelineMismatch }
            let actualOffset = try parsed.writtenRange.start.subtracting(first.pts)
            guard offset == nil || offset == actualOffset,
                  nextWritten == nil || nextWritten == parsed.writtenRange.start else {
                throw SourceAACFailure.timelineMismatch
            }
            for index in samples.indices {
                guard let parsedSample = parsed.sample(at: index),
                      parsedSample.presentationRange.start == (try samples[index].pts.adding(actualOffset)),
                      parsedSample.presentationRange.duration == samples[index].duration,
                      case let .aac(_, _, _, digest) = samples[index].identity,
                      bytes.withUnsafeBytes({ raw in
                          Data(SHA256.hash(data: UnsafeRawBufferPointer(rebasing: raw[parsedSample.byteSpan])))
                      }) == digest else {
                    throw SourceAACFailure.sourceMismatch
                }
            }
            let callbackCharge = try HLSCompressedAudioApplicationReservation.reserve(bytes: 2_048,
                ledger: applicationLedger)
            let nextCount = callbackSampleCount.addingReportingOverflow(UInt64(samples.count))
            guard !nextCount.overflow else { throw SourceAACFailure.timelineMismatch }
            callbackSampleCount = nextCount.partialValue; currentWindowCallbackCount += samples.count
            offset = actualOffset; firstWritten = firstWritten ?? parsed.writtenRange.start
            nextWritten = parsed.writtenRange.end; lastCallbackSequence = sequence
            return .init(origin: origin, kind: kind, sequence: sequence,
                digest: Data(SHA256.hash(data: bytes)), reportIdentity: report.identity,
                range: parsed.writtenRange, offset: actualOffset, sampleCount: samples.count,
                sampleEntryDigest: sampleEntryDigest, charge: callbackCharge)
        }
    }
    func finishWindow(origin: SourceAACWriterOrigin, terminal: SegmentedFMP4WriterTerminalReceipt) throws {
        try lock.withLock {
            guard !failed, currentOrigin == origin.identity, terminal.binding == currentBinding,
                  terminal.terminalReason == .finished, terminal.inputCount == currentWindowInputCount,
                  terminal.initializationCallbackCount == 1, terminal.mediaCallbackCount > 0,
                  currentWindowInputCount == currentWindowCallbackCount,
                  callbackSampleCount == inputCount, let offset, let nextWritten,
                  nextWritten == (try nextInput.adding(offset)) else { throw SourceAACFailure.timelineMismatch }
            windowTerminal = terminal
        }
    }
    func sealSourceEOF(origin: SourceAACWriterOrigin, terminal: SegmentedFMP4WriterTerminalReceipt) throws -> SourceAACFinalSeal {
        try lock.withLock {
            if let storedFinal { return storedFinal }
            guard !failed, currentOrigin == origin.identity, windowTerminal == terminal,
                  let lastSourceID, configuration.authority.stream.isDrained(throughFrameID: lastSourceID),
                  let offset, let firstWritten, let nextWritten, let lastCallbackSequence,
                  let sampleEntryDigest else { throw SourceAACFailure.sourceMismatch }
            let seal = SourceAACFinalSeal(authority: configuration.authority.identity, terminal: terminal,
                lastSourceID: lastSourceID, inputCount: inputCount, sequence: lastCallbackSequence,
                offset: offset, start: firstWritten, end: nextWritten, digest: sampleEntryDigest)
            storedFinal = seal
            return seal
        }
    }
    func accepts(_ evidence: SourceAACCallbackEvidence) -> Bool {
        lock.withLock { !failed && evidence.authorityIdentity == configuration.authority.identity
            && evidence.sampleEntryDigest == sampleEntryDigest }
    }
    /// Validates only coordinates already derived from verified source callbacks.
    /// It cannot confer HTTP completion, selection or paused-scope authority.
    func validatesTimeline(writtenPhysicalBase: ExactMediaTime,
                           writtenEffectiveBase: ExactMediaTime,
                           effectivePlaybackHorizon: ExactMediaTime) -> Bool {
        lock.withLock {
            guard !failed, configuration.authority.stream.isCurrent,
                  let firstWritten, let nextWritten, offset != nil,
                  writtenPhysicalBase == firstWritten, writtenEffectiveBase == firstWritten,
                  CMTimeCompare(effectivePlaybackHorizon.cmTime, firstWritten.cmTime) > 0,
                  CMTimeCompare(effectivePlaybackHorizon.cmTime, nextWritten.cmTime) <= 0 else { return false }
            return true
        }
    }
    var writtenStart: ExactMediaTime? { lock.withLock { failed ? nil : firstWritten } }
    var writtenEnd: ExactMediaTime? { lock.withLock { failed ? nil : nextWritten } }

#if DEBUG
    func inspectPreparationBindingAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        lock.withLock {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            body("Shared source AAC terminal binding (prepaid source authority)", pointer, malloc_size(pointer))
            let lockPointer = UnsafeRawPointer(Unmanaged.passUnretained(lock).toOpaque())
            body("Shared source AAC terminal lock (prepaid source authority)", lockPointer, malloc_size(lockPointer))
            inspectNativePreparationWeakSideTable("source AAC terminal binding", self, body)
        }
    }
#endif
    func fail() { lock.withLock { failed = true; storedFinal = nil } }
}
