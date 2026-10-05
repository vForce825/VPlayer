// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation

enum DolbyAudioSourceFailure: Error, Sendable, Equatable {
    case unsupportedSource
    case invalidSourceProof
    case sourceAlreadyConsumed
    case sourceNotDrained
    case sourcePoisoned
    case capacityExceeded
    case missingOutputAuthority
}

/// A native alias retains bytes and paid tails only. It must never retain the
/// producer, coordinator, timeline, branch, or graph that submitted those bytes.
final class DolbyAudioPayloadLifetime: @unchecked Sendable {
    private let bytes: Data
    private let tails: [HLSAudioCopyTail]
    private let members: [DolbyAudioPayloadLifetime]
    private let copyOwnership: HLSAudioCopyOwnership?
    private let sourceReservation: HLSCompressedAudioApplicationReservation?

    fileprivate init(bytes: Data, tails: [HLSAudioCopyTail], members: [DolbyAudioPayloadLifetime] = [],
                     copyOwnership: HLSAudioCopyOwnership? = nil,
                     sourceReservation: HLSCompressedAudioApplicationReservation? = nil) {
        self.bytes = bytes; self.tails = tails; self.members = members
        self.copyOwnership = copyOwnership; self.sourceReservation = sourceReservation
    }

    static func aggregate(bytes: Data, reservation: HLSAudioCopyTail,
                          members: [DolbyAudioFrameProof]) throws -> DolbyAudioPayloadLifetime {
        guard (1...6).contains(members.count), bytes.count <= 6 * 4_096 else {
            throw DolbyAudioSourceFailure.invalidSourceProof
        }
        return DolbyAudioPayloadLifetime(bytes: bytes, tails: [reservation],
            members: members.map(\.payloadLifetime))
    }
}

/// Deliberately separate from the producer: retaining a frame or native alias
/// cannot keep the coordinator's graph authority alive.
fileprivate final class DolbyAudioSourceState: @unchecked Sendable {
    let identity = UUID()
    private let lock = NSLock()
    let charge: HLSCompressedAudioApplicationReservation
    private var valid = true
    private var drained = false
    private var outputStarted = false
    private var lastID: UInt64?
    private var sourceGeneration: MediaGeneration?
    private var format: CompressedAudioFormatConfiguration?
    private var nextPresentationTime: CMTime?

    init(charge: HLSCompressedAudioApplicationReservation) { self.charge = charge }

    func issue(id: UInt64, generation: MediaGeneration, configuration: CompressedAudioFormatConfiguration,
               start: CMTime, duration: CMTime) throws {
        try lock.withLock {
            guard valid, !drained else { throw DolbyAudioSourceFailure.sourcePoisoned }
            guard id > 0, lastID.map({ id > $0 }) ?? true,
                  sourceGeneration == nil || sourceGeneration == generation,
                  format == nil || format == configuration,
                  start.isNumeric, duration.isNumeric, CMTimeCompare(duration, .zero) > 0,
                  nextPresentationTime.map({ CMTimeCompare(start, $0) == 0 }) ?? true else {
                valid = false
                throw DolbyAudioSourceFailure.invalidSourceProof
            }
            lastID = id; sourceGeneration = generation; format = configuration
            nextPresentationTime = CMTimeAdd(start, duration)
            guard nextPresentationTime?.isNumeric == true else {
                valid = false
                throw DolbyAudioSourceFailure.invalidSourceProof
            }
        }
    }
    var isCurrent: Bool { lock.withLock { valid } }
    var canAbandonBeforeOutput: Bool { lock.withLock { valid && !outputStarted } }
    func beginOutput() throws {
        try lock.withLock {
            guard valid else { throw DolbyAudioSourceFailure.sourcePoisoned }
            outputStarted = true
        }
    }
    func finish() throws {
        try lock.withLock {
            guard valid, !drained, lastID != nil else { throw DolbyAudioSourceFailure.sourceNotDrained }
            drained = true
        }
    }
    func requireDrained(through id: UInt64) throws {
        try lock.withLock {
            guard valid, drained, lastID == id else { throw DolbyAudioSourceFailure.sourceNotDrained }
        }
    }
    func invalidate() { lock.withLock { valid = false } }
    func abandonUnlessDrained() { lock.withLock { if !drained { valid = false } } }
}

/// Only the paid producer below can construct this proof. Its one-shot bit
/// stays with the frame, so registry retirement needs no growing replay table.
final class DolbyAudioFrameProof: @unchecked Sendable {
    let identity = UUID()
    let id: UInt64
    let generation: MediaGeneration
    let presentationTimeStamp: CMTime
    let duration: CMTime
    let codecFacts: AudioServiceCodecFacts
    let inputUnit: AudioServiceInputUnit
    let configuration: CompressedAudioFormatConfiguration
    let sourceLayout: AudioChannelLayout
    let systemFormat: SystemCompressedAudioFormat
    let payloadLifetime: DolbyAudioPayloadLifetime
    let payloadSHA256: Data
    private let state: DolbyAudioSourceState
    private let admissionLock = NSLock()
    private var admissionAttempted = false
    private var storedAdmittedProof: AdmittedAudioServiceInputUnitProof?

    fileprivate init(id: UInt64, generation: MediaGeneration, duration: CMTime,
                     codecFacts: AudioServiceCodecFacts, inputUnit: AudioServiceInputUnit,
                     configuration: CompressedAudioFormatConfiguration, sourceLayout: AudioChannelLayout,
                     systemFormat: SystemCompressedAudioFormat, lifetime: DolbyAudioPayloadLifetime,
                     state: DolbyAudioSourceState) {
        self.id = id; self.generation = generation; presentationTimeStamp = inputUnit.presentationTimeStamp
        self.duration = duration; self.codecFacts = codecFacts; self.inputUnit = inputUnit
        self.configuration = configuration; self.sourceLayout = sourceLayout; self.systemFormat = systemFormat
        payloadLifetime = lifetime; payloadSHA256 = Data(SHA256.hash(data: inputUnit.bytes)); self.state = state
    }
    var sourceIdentity: UUID { state.identity }
    var isCurrent: Bool { state.isCurrent }
    var admittedProof: AdmittedAudioServiceInputUnitProof? { admissionLock.withLock { storedAdmittedProof } }
    func validates(_ frame: CompressedAudioFrame) -> Bool {
        frame.dolbyProof === self && state.isCurrent && frame.id == id && frame.generation == generation
            && frame.codec == configuration.codec && frame.frameSampleCount == codecFacts.sampleCount
            && CMTimeCompare(frame.presentationTimeStamp, presentationTimeStamp) == 0
            && CMTimeCompare(frame.duration, duration) == 0 && frame.payload.count == inputUnit.byteRange.length
            && Data(SHA256.hash(data: frame.payload)) == payloadSHA256
    }
    fileprivate func claimAdmission(for state: DolbyAudioSourceState) -> Bool {
        admissionLock.withLock {
            guard self.state === state, state.isCurrent, !admissionAttempted else { return false }
            admissionAttempted = true
            return true
        }
    }
    fileprivate func didAdmit(_ proof: AdmittedAudioServiceInputUnitProof) {
        admissionLock.withLock { storedAdmittedProof = proof }
    }
    /// Drop the service graph record after the branch has performed its final
    /// post-await validation. The immutable consumed bit deliberately survives.
    func forgetRetiredAdmission() { admissionLock.withLock { storedAdmittedProof = nil } }
}

final class DolbyAudioSourceProducer: @unchecked Sendable {
    let binding: FMP4WriterBinding
    let coordinator: AudioServiceSemanticCoordinator
    let sharedControlExecutor: PlaybackControlExecutor
    let source: AudioTrackDescriptor
    let allocator: PlaybackIdentityAllocator
    private let tracks: DemuxTrackSet
    private let applicationLedger: HLSDeliveryApplicationChargeLedger
    private let copyOwnership: HLSAudioCopyOwnership
    private let state: DolbyAudioSourceState
    private var establishedOutputPlan: CompressedAudioOutputPlanBinding?

    init(tracks: DemuxTrackSet, binding: FMP4WriterBinding,
         sharedControlExecutor: PlaybackControlExecutor, copyOwnership: HLSAudioCopyOwnership,
         applicationLedger: HLSDeliveryApplicationChargeLedger = .shared) throws {
        guard let source = tracks.audio, [.ac3, .eac3].contains(source.codec),
              source.sampleRate > 0 else { throw DolbyAudioSourceFailure.unsupportedSource }
        _ = try CompressedAudioChannelPositions.bitmap(from: source.channelLayout)
        let charge = try HLSCompressedAudioApplicationReservation.reserve(bytes: 16_384, ledger: applicationLedger)
        state = DolbyAudioSourceState(charge: charge)
        self.source = source; self.tracks = tracks; self.binding = binding
        self.applicationLedger = applicationLedger
        self.sharedControlExecutor = sharedControlExecutor; self.copyOwnership = copyOwnership
        let allocator = PlaybackIdentityAllocator()
        self.allocator = allocator
        let owner = CompressedAudioBranchOwnerIdentity.audioVideo(outputLifecycleEpoch: binding.outputLifecycleEpoch,
            itemGeneration: binding.itemGeneration, mediaEpoch: binding.mediaEpoch,
            publicationParticipantID: binding.publicationParticipantID, renditionIdentity: binding.renditionIdentity)
        let branchGeneration = try allocator.next(in: .nonce)
        let fence = try allocator.next(in: .nonce)
        let admission: AudioBranchAdmissionIdentity = source.codec == .ac3
            ? .directCompressed(owner, branchGeneration: branchGeneration, admissionFenceRevision: fence)
            : .eac3Aggregation(owner, branchGeneration: branchGeneration, admissionFenceRevision: fence)
        coordinator = AudioServiceSemanticCoordinator(source: source,
            sourceTrackIdentity: .init(streamIndex: source.streamIndex, trackNonce: try allocator.next(in: .nonce)),
            inputFormatGeneration: .init(rawValue: try allocator.next(in: .nonce)), allocator: allocator,
            compressedOutputAdmissionAuthority: admission, sharedControlExecutor: sharedControlExecutor,
            applicationLedger: applicationLedger)
    }
    deinit { state.abandonUnlessDrained() }
    var identity: UUID { state.identity }
    var isCurrent: Bool { state.isCurrent }
    var canAbandonBeforeOutput: Bool { state.canAbandonBeforeOutput }
    var outputPlanBinding: CompressedAudioOutputPlanBinding? {
        sharedControlExecutor.sync { state.isCurrent ? establishedOutputPlan : nil }
    }

    func makeProof(id: UInt64, generation: MediaGeneration, framed: FramedCompressedAudioFrame,
                   inspected: InspectedCompressedAudioFrame) throws -> DolbyAudioFrameProof {
        try sharedControlExecutor.sync {
            do {
                guard state.isCurrent, let sourceTail = framed.hlsCopyTail,
                      !framed.containerMarkedCorrupt, (8...4_096).contains(framed.payload.count),
                      framed.payload == inspected.payload else { throw DolbyAudioSourceFailure.invalidSourceProof }
                // Header parsing, digest validation and existing service code use
                // bounded scratch copies. Pay their maximum overlap before any copy.
                guard let lease = copyOwnership.compressedInput.acquire(bytes: 8 * framed.payload.count + 4_096) else {
                    throw DolbyAudioSourceFailure.capacityExceeded
                }
                let metadataAndScratch = HLSAudioCopyTail(lease)
                let profile = try AudioCodecProfileRegistry.profile(for: source)
                let actual = try profile.inspect(framed, source: source)
                guard actual.sampleCount == inspected.sampleCount,
                      actual.systemFormat == inspected.systemFormat else {
                    throw DolbyAudioSourceFailure.invalidSourceProof
                }
                let header = try Self.headerConfiguration(framed.payload, source: source)
                let configuration = header.configuration
                let duration = CMTime(value: Int64(actual.sampleCount), timescale: source.sampleRate)
                let bytes = AudioServiceInputBacking(identity: .init(rawValue: try allocator.next(in: .resource)),
                    bytes: framed.payload)
                let unit = try AudioServiceInputUnit(identity: .init(rawValue: try allocator.next(in: .nonce)),
                    backing: bytes, byteRange: AudioServiceByteRange(offset: 0, length: framed.payload.count)!,
                    presentationTimeStamp: framed.presentationTimeStamp,
                    parserSampleCount: framed.parserSampleCount, parserSampleRate: framed.parserSampleRate,
                    parserChannelLayout: framed.parserChannelLayout, containerMarkedCorrupt: false)
                if establishedOutputPlan == nil {
                    let receipt = try coordinator.establishReceipt(selectedProgramID: tracks.selectedProgramID,
                        firstInputUnit: unit, audioPrimaryEvidence: tracks.audioPrimaryEvidence)
                    guard receipt.semantic == .independentMain,
                          let plan = coordinator.bindCompressedOutputPlan() else {
                        throw DolbyAudioSourceFailure.unsupportedSource
                    }
                    establishedOutputPlan = plan
                }
                try state.issue(id: id, generation: generation, configuration: configuration,
                    start: framed.presentationTimeStamp, duration: duration)
                let lifetime = DolbyAudioPayloadLifetime(bytes: framed.payload,
                    tails: [sourceTail, metadataAndScratch], copyOwnership: copyOwnership,
                    sourceReservation: state.charge)
                return DolbyAudioFrameProof(id: id, generation: generation, duration: duration,
                    codecFacts: .init(profileID: actual.systemFormat.profileID, sampleRate: source.sampleRate,
                        sampleCount: actual.sampleCount, channelCount: source.channelLayout.channelCount,
                        eac3BlockCount: source.codec == .eac3 ? Int(actual.sampleCount / 256) : nil),
                    inputUnit: unit, configuration: configuration, sourceLayout: source.channelLayout,
                    systemFormat: header.systemFormat, lifetime: lifetime, state: state)
            } catch {
                state.invalidate()
                throw error
            }
        }
    }

    func admitForOutput(_ proof: DolbyAudioFrameProof) throws -> AdmittedAudioServiceInputUnitProof {
        try sharedControlExecutor.sync {
            guard proof.claimAdmission(for: state) else { throw DolbyAudioSourceFailure.sourceAlreadyConsumed }
            let nonce = try coordinator.installValidation(for: proof.inputUnit)
            let semanticProof = try coordinator.makeProof(for: proof.inputUnit, validationNonce: nonce)
            guard semanticProof.observedSemantic == .independentMain,
                  semanticProof.codecFacts == proof.codecFacts else { throw DolbyAudioSourceFailure.invalidSourceProof }
            let lifetime = proof.payloadLifetime
            let ownership = AudioServiceInputUnitOwnership(onRelease: { withExtendedLifetime(lifetime) {} })
            switch coordinator.admit(semanticProof, ownership: ownership) {
            case let .admitted(admitted): proof.didAdmit(admitted); return admitted
            case let .failed(error): throw error
            case .ignored: throw DolbyAudioSourceFailure.invalidSourceProof
            }
        }
    }

    func makeCapacityWakeup() throws -> WriterCapacityWakeup { try .make(ledger: applicationLedger) }

    func reserveBranchStorage() throws -> HLSCompressedAudioApplicationReservation {
        try HLSCompressedAudioApplicationReservation.reserve(bytes: 16_384, ledger: applicationLedger)
    }

    func reserveAggregateCopy() throws -> HLSAudioCopyTail {
        // Up to six 4,096-byte syncframes plus bounded commit/digest scratch.
        guard let lease = copyOwnership.compressedInput.acquire(bytes: 4 * 6 * 4_096 + 4_096) else {
            throw DolbyAudioSourceFailure.capacityExceeded
        }
        return HLSAudioCopyTail(lease)
    }
    func beginOutput() throws { try state.beginOutput() }
    func finishSourceInput() throws { try state.finish() }
    func invalidateSourceInput() {
        state.invalidate()
        coordinator.invalidateCompressedSourceAuthority()
        sharedControlExecutor.sync { establishedOutputPlan = nil }
    }
    func requireSourceDrained(throughFrameID id: UInt64) throws { try state.requireDrained(through: id) }
    func cancel() { invalidateSourceInput() }

    private static func headerConfiguration(_ bytes: Data, source: AudioTrackDescriptor)
        throws -> (configuration: CompressedAudioFormatConfiguration, systemFormat: SystemCompressedAudioFormat) {
        let configuration: CompressedAudioFormatConfiguration
        let sampleRate: Int32
        let channelCount: Int32
        let codingMode: UInt8
        let hasLFE: Bool
        switch source.codec {
        case .ac3:
            let header = try AC3FrameInspector.inspect(bytes)
            guard header.bsmod == 0 else { throw DolbyAudioSourceFailure.unsupportedSource }
            configuration = .ac3(try AC3CompressedAudioConfiguration(inspection: header))
            sampleRate = header.sampleRate; channelCount = header.channelCount
            codingMode = header.acmod; hasLFE = header.lfeon
        case .eac3:
            let header = try EAC3FrameInspector.inspect(bytes)
            guard header.streamType == .independent, header.substreamID == 0,
                  header.bsmod == 0, header.hasJOC == false else { throw DolbyAudioSourceFailure.unsupportedSource }
            configuration = .eac3(try EAC3CompressedAudioConfiguration(sampleRate: header.sampleRate,
                bsid: header.bsid, bsmod: 0, audioCodingMode: header.acmod, hasLFE: header.lfeon,
                asvc: false, maximumDataRateKbps: EAC3AccessUnitAssembler.trustedParserDomainMaximumDataRateKbps))
            sampleRate = header.sampleRate; channelCount = header.channelCount
            codingMode = header.acmod; hasLFE = header.lfeon
        default: throw DolbyAudioSourceFailure.unsupportedSource
        }
        guard (1...7).contains(codingMode), source.sampleRate == sampleRate,
              source.channelLayout.channelCount == channelCount,
              let mask = source.channelLayout.nativeMask else { throw DolbyAudioSourceFailure.unsupportedSource }
        // Dolby surround coding does not identify back-vs-side positions. Keep
        // that distinction from the exact source layout and validate emitted chan.
        let bases: [UInt64] = [0, 0x4, 0x3, 0x7, 0x103, 0x107, 0x33, 0x37]
        let back = bases[Int(codingMode)] | (hasLFE ? 0x8 : 0)
        let side = codingMode >= 6 ? (back & ~UInt64(0x30)) | 0x600 : back
        guard mask == back || mask == side else { throw DolbyAudioSourceFailure.unsupportedSource }
        let bitmap = try CompressedAudioChannelPositions.bitmap(from: source.channelLayout)
        let cookie = configuration.serializedBox
        return (configuration, .init(profileID: source.codec == .ac3 ? .ac3 : .eac3,
            codec: source.codec, formatID: source.codec == .ac3 ? kAudioFormatAC3 : kAudioFormatEnhancedAC3,
            sampleRate: sampleRate, channelCount: channelCount, framesPerPacket: 1_536,
            layout: .bitmap(AudioChannelBitmap(rawValue: bitmap)), magicCookie: cookie))
    }
}
