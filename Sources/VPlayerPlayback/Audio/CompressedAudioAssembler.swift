// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CryptoKit
import Foundation

/// A bounded source lifetime, issued only by the paid assembler below. EOF is
/// independent of writer-window completion; cancellation cannot manufacture EOF.
final class CompressedAudioSourceStream: @unchecked Sendable {
    let identity = UUID()
    private let lock = NSLock()
    private let ownership: HLSAudioCopyTail
    private var valid = true
    private var drained = false
    private var lastFrameID: UInt64?
    private var rendition: UUID?
    private var hasClaimedInput = false

    fileprivate static func make(_ copies: HLSAudioCopyOwnership) throws -> CompressedAudioSourceStream {
        guard let lease = copies.compressedInput.acquire(bytes: 2_048) else {
            throw CompressedAudioAssembler.validationError()
        }
        return CompressedAudioSourceStream(ownership: HLSAudioCopyTail(lease))
    }
    private init(ownership: HLSAudioCopyTail) { self.ownership = ownership }
    fileprivate func issued(_ id: UInt64) throws {
        try lock.withLock {
            guard valid, !drained, lastFrameID.map({ id > $0 }) ?? true else {
                throw CompressedAudioAssembler.validationError()
            }
            lastFrameID = id
        }
    }
    fileprivate func finish() { lock.withLock { if valid { drained = true } } }
    fileprivate func abandonUnlessDrained() { lock.withLock { if !drained { valid = false } } }
    func invalidate() { lock.withLock { valid = false } }
    var isCurrent: Bool { lock.withLock { valid } }
    func isDrained(throughFrameID id: UInt64) -> Bool {
        lock.withLock { valid && drained && lastFrameID == id }
    }
    /// One stable rendition authority, shared by all physical writer windows.
    func bindRendition(_ identity: UUID) -> Bool {
        lock.withLock {
            guard valid, rendition == nil else { return false }
            rendition = identity
            return true
        }
    }
    func acceptsRendition(_ identity: UUID) -> Bool {
        lock.withLock { valid && rendition == identity }
    }
    fileprivate func claimInput(for identity: UUID) -> Bool {
        lock.withLock {
            guard valid, rendition == identity else { return false }
            hasClaimedInput = true
            return true
        }
    }
    func abandonBeforeClaim() -> Bool {
        lock.withLock {
            guard !hasClaimedInput else { return false }
            valid = false
            return true
        }
    }
}

/// Immutable evidence from real framing/profile inspection. There is deliberately
/// no externally accessible initializer taking arbitrary Data as a source proof.
final class CompressedAudioSourceProof: @unchecked Sendable {
    let identity = UUID()
    let id: UInt64
    let stream: CompressedAudioSourceStream
    let generation: MediaGeneration
    let presentationTimeStamp: CMTime
    let duration: CMTime
    let sourceLayout: AudioChannelLayout
    let decoderConfiguration: Data
    let format: SystemCompressedAudioFormat
    let formatDescription: CMAudioFormatDescription
    let payloadSHA256: Data
    let payloadByteCount: Int
    private let payloadTail: HLSAudioCopyTail
    private let metadataTail: HLSAudioCopyTail
    private let copyOwnership: HLSAudioCopyOwnership
    private let claimLock = NSLock()
    private var claimed = false

    fileprivate init(id: UInt64, stream: CompressedAudioSourceStream,
                     descriptor: AudioTrackDescriptor, generation: MediaGeneration,
                     presentationTimeStamp: CMTime, duration: CMTime,
                     inspected: InspectedCompressedAudioFrame,
                     formatDescription: CMAudioFormatDescription,
                     copyOwnership: HLSAudioCopyOwnership,
                     payloadTail: HLSAudioCopyTail, metadataTail: HLSAudioCopyTail) {
        self.id = id; self.stream = stream; self.generation = generation
        self.presentationTimeStamp = presentationTimeStamp; self.duration = duration
        sourceLayout = descriptor.channelLayout; decoderConfiguration = inspected.decoderExtradata
        format = inspected.systemFormat; self.formatDescription = formatDescription
        payloadSHA256 = Data(SHA256.hash(data: inspected.payload))
        payloadByteCount = inspected.payload.count
        self.copyOwnership = copyOwnership; self.payloadTail = payloadTail; self.metadataTail = metadataTail
    }
    func validates(_ frame: CompressedAudioFrame) -> Bool {
        frame.sourceProof === self && stream.isCurrent && frame.id == id
            && frame.codec == .aac && frame.generation == generation
            && frame.frameSampleCount == 1_024 && frame.payload.count == payloadByteCount
            && CMTimeCompare(frame.presentationTimeStamp, presentationTimeStamp) == 0
            && CMTimeCompare(frame.duration, duration) == 0
            && Data(SHA256.hash(data: frame.payload)) == payloadSHA256
    }
    /// Called only after actual writer capacity has been paid. Rejection cannot
    /// reset a consumed source AU or let it enter a second native writer.
    func claim(for rendition: UUID) -> Bool {
        claimLock.withLock {
            guard !claimed, stream.claimInput(for: rendition) else { return false }
            claimed = true
            return true
        }
    }
}

final class CompressedAudioAssembler {
    static let invalidInputErrorCode: Int32 = -1_448_208_897
    static let idExhaustedErrorCode: Int32 = -1_448_208_899

    private let generationProvider: () -> MediaGeneration
    private let eventSink: (AudioAssemblerEvent) -> Void
    private let parserFactory: any FFmpegParserFactory
    private let binding: AssemblyEpochBinding
    private let formatState: AssemblyFormatState
    private let descriptor: AudioTrackDescriptor
    private let profile: any CompressedAudioCodecProfile
    private let hlsCopyOwnership: HLSAudioCopyOwnership?
    let sourceStream: CompressedAudioSourceStream?
    private var sourceAACProofEnabled = true
    private var framer: (any CompressedAudioFramingStrategy)?
    private var nextID: UInt64?
    private var systemFormat: SystemCompressedAudioFormat?
    private var formatDescription: CMAudioFormatDescription?
    private var emittedFingerprint: MediaFormatFingerprint?
    private var framerOperationID: AssemblyOperationID?

    private struct AudioUnitRejection: Error {
        let reason: AudioDecodeBreakReason
    }

    init(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping () -> MediaGeneration,
        eventSink: @escaping (AudioAssemblerEvent) -> Void,
        parserFactory: any FFmpegParserFactory = LiveFFmpegParserFactory(),
        formatState: AssemblyFormatState,
        binding: AssemblyEpochBinding = .standalone(),
        startingID: UInt64 = 1,
        hlsCopyOwnership: HLSAudioCopyOwnership? = nil
    ) throws {
        guard let descriptor = trackSet.audio else { throw Self.validationError() }
        self.descriptor = descriptor
        profile = try AudioCodecProfileRegistry.profile(for: descriptor)
        self.generationProvider = generationProvider
        self.eventSink = eventSink
        self.parserFactory = parserFactory
        self.formatState = formatState
        self.binding = binding
        self.hlsCopyOwnership = hlsCopyOwnership
        sourceStream = descriptor.codec == .aac
            ? try hlsCopyOwnership.map(CompressedAudioSourceStream.make) : nil
        nextID = startingID
        try configureProfileAndFramer()
    }

    deinit {
        sourceStream?.abandonUnlessDrained()
        framer?.destroy()
    }

    /// Before any native/source claim, fallback keeps this exact framer and its
    /// partial AU carry. Existing queued frame aliases keep their paid backing.
    func useCompatibleAudioBeforeSourceAppend() throws {
        guard sourceStream?.abandonBeforeClaim() ?? true else { throw SourceAACFailure.sourceAlreadyConsumed }
        sourceAACProofEnabled = false
    }

    func push(_ packet: DemuxPacket) throws {
        try ensureFramerIsCurrent()
        let continuingWithoutPTS = !packet.presentationTimeStamp.isValid &&
            framer?.canContinueWithoutTimestamp == true
        guard packet.streamIndex == descriptor.streamIndex,
              packet.codec == .audio(descriptor.codec),
              !packet.data.isEmpty,
              packet.presentationTimeStamp.isNumeric || continuingWithoutPTS else {
            throw Self.validationError()
        }
        let pts: Int64
        if continuingWithoutPTS {
            pts = Int64.min
        } else {
            pts = try audioExactTicks(packet.presentationTimeStamp, timeBase: descriptor.timeBase)
        }
        let presentationTimeStamp = descriptor.timeBase.cmTime(forFFmpegValue: pts)
        guard presentationTimeStamp.isNumeric || continuingWithoutPTS else { throw Self.validationError() }
        let framedPacket = CompressedAudioFramingPacket(
            data: packet.data,
            presentationTimeStamp: presentationTimeStamp,
            pts: pts,
            dts: try audioOptionalTicks(packet.decodeTimeStamp, timeBase: descriptor.timeBase),
            duration: try audioOptionalDurationTicks(packet.duration, timeBase: descriptor.timeBase),
            containerMarkedCorrupt: packet.isCorrupt
        )
        do {
            try framer?.push(framedPacket)
        } catch let error as PlaybackCoreError
            where error == .audioFallbackDecode(Self.idExhaustedErrorCode) {
            throw error
        } catch let rejection as AudioUnitRejection {
            try rejectCurrentUnit(reason: rejection.reason)
        } catch {
            try rejectCurrentUnit(reason: .framingReset)
        }
    }

    func drain() throws {
        try ensureFramerIsCurrent()
        do {
            try framer?.drain()
            sourceStream?.finish()
        } catch let error as PlaybackCoreError
            where error == .audioFallbackDecode(Self.idExhaustedErrorCode) {
            throw error
        } catch let rejection as AudioUnitRejection {
            try rejectCurrentUnit(reason: rejection.reason)
        } catch {
            try rejectCurrentUnit(reason: .framingReset)
        }
    }

    private func configureProfileAndFramer() throws {
        guard descriptor.sampleRate > 0, descriptor.channelLayout.channelCount > 0 else {
            throw Self.validationError()
        }
        if let initial = try profile.initialSystemFormat(source: descriptor) {
            try install(initial)
        }
        let operationID = try currentOperationID()
        framerOperationID = operationID
        framer = try makeFramer(operationID: operationID)
    }

    private func makeFramer(
        operationID: AssemblyOperationID
    ) throws -> any CompressedAudioFramingStrategy {
        let receiver: (FramedCompressedAudioFrame) throws -> Void = { [weak self] frame in
            guard let self, binding.accepts(operationID) else { return }
            try receive(frame)
        }
        switch profile.framing {
        case .rawAAC:
            return RawAACFramingStrategy(hlsCopyOwnership: hlsCopyOwnership, receiver: receiver)
        case .adts:
            return ADTSAudioFramingStrategy(
                sampleRate: descriptor.sampleRate,
                hlsCopyOwnership: hlsCopyOwnership,
                receiver: receiver
            )
        case .ffmpegParser:
            return try FFmpegCompressedAudioFramingStrategy(
                source: descriptor,
                parserFactory: parserFactory,
                hlsCopyOwnership: hlsCopyOwnership,
                receiver: receiver
            )
        }
    }

    private func currentOperationID() throws -> AssemblyOperationID {
        guard let operationID = binding.currentOperationID() else {
            throw Self.validationError()
        }
        return operationID
    }

    private func ensureFramerIsCurrent() throws {
        let operationID = try currentOperationID()
        guard framerOperationID != operationID else { return }
        sourceStream?.invalidate()
        framer?.destroy()
        framer = nil
        framerOperationID = operationID
        framer = try makeFramer(operationID: operationID)
    }

    private func receive(_ framed: FramedCompressedAudioFrame) throws {
        // ADTS removal allocates a distinct payload backing; reserve before inspection.
        let payloadLease = profile.framing == .adts
            ? hlsCopyOwnership?.compressedInput.acquire(bytes: framed.payload.count) : nil
        guard profile.framing != .adts || hlsCopyOwnership == nil || payloadLease != nil else {
            throw AudioUnitRejection(reason: .invalidFrame)
        }
        let payloadTail = payloadLease.map(HLSAudioCopyTail.init)
        let inspected: InspectedCompressedAudioFrame
        do {
            inspected = try profile.inspect(framed, source: descriptor)
        } catch {
            throw AudioUnitRejection(reason: profile.decodeBreakReason(
                forRejected: framed,
                source: descriptor
            ))
        }
        do {
            try install(inspected.systemFormat)
            guard let formatDescription else { throw Self.validationError() }
            let fingerprint = try formatState.fingerprint()
            if fingerprint != emittedFingerprint {
                eventSink(.format(CompressedAudioRenderConfiguration(
                    formatDescription: formatDescription,
                    codec: descriptor.codec,
                    decoderExtradata: inspected.decoderExtradata,
                    fingerprint: fingerprint
                )))
                emittedFingerprint = fingerprint
            }
            let id = try takeNextID()
            let generation = generationProvider()
            let duration = CMTime(
                value: Int64(inspected.sampleCount),
                timescale: inspected.systemFormat.sampleRate
            )
            guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
                throw Self.validationError()
            }
            if sourceAACProofEnabled, inspected.systemFormat.profileID == .aacLC, inspected.sampleCount == 1_024,
               let hlsCopyOwnership, let sourceStream {
                guard let ownedPayload = payloadTail ?? framed.hlsCopyTail,
                      let proofLease = hlsCopyOwnership.compressedInput.acquire(bytes: 2_048) else {
                    throw Self.validationError()
                }
                let metadataTail = HLSAudioCopyTail(proofLease)
                try sourceStream.issued(id)
                let proof = CompressedAudioSourceProof(id: id, stream: sourceStream, descriptor: descriptor,
                    generation: generation, presentationTimeStamp: framed.presentationTimeStamp,
                    duration: duration, inspected: inspected, formatDescription: formatDescription,
                    copyOwnership: hlsCopyOwnership, payloadTail: ownedPayload, metadataTail: metadataTail)
                eventSink(.frame(CompressedAudioFrame(id: id, payload: inspected.payload,
                    codec: descriptor.codec, generation: generation,
                    presentationTimeStamp: framed.presentationTimeStamp, duration: duration,
                    frameSampleCount: inspected.sampleCount, sourceProof: proof)))
            } else {
                eventSink(.frame(CompressedAudioFrame(id: id, payload: inspected.payload,
                    codec: descriptor.codec, generation: generation,
                    presentationTimeStamp: framed.presentationTimeStamp, duration: duration,
                    frameSampleCount: inspected.sampleCount,
                    payloadOwnership: payloadTail ?? framed.hlsCopyTail)))
            }
        } catch let error as PlaybackCoreError
            where error == .audioFallbackDecode(Self.idExhaustedErrorCode) {
            throw error
        } catch {
            throw AudioUnitRejection(reason: .invalidFrame)
        }
    }

    private func install(_ newFormat: SystemCompressedAudioFormat) throws {
        guard newFormat.codec == descriptor.codec else { throw Self.validationError() }
        guard systemFormat != newFormat || formatDescription == nil else { return }
        let built = try AudioFormatDescriptionBuilder.make(newFormat)
        systemFormat = newFormat
        formatDescription = built.description
        formatState.commitAudioSystemFormat(AudioSystemFormatFingerprintComponent(newFormat))
    }

    private func rejectCurrentUnit(reason: AudioDecodeBreakReason) throws {
        sourceStream?.invalidate()
        framer?.destroy()
        framer = nil
        let operationID = try currentOperationID()
        framerOperationID = operationID
        framer = try makeFramer(operationID: operationID)
        eventSink(.decodeBreak(reason))
    }

    private func takeNextID() throws -> UInt64 {
        guard let id = nextID else {
            throw PlaybackCoreError.audioFallbackDecode(Self.idExhaustedErrorCode)
        }
        nextID = id == UInt64.max ? nil : id + 1
        return id
    }

    fileprivate static func validationError() -> PlaybackCoreError {
        .audioFallbackDecode(invalidInputErrorCode)
    }
}

private func audioExactTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64 {
    do {
        guard let value = try exactTicks(time, timeBase: timeBase) else {
            throw CompressedAudioAssembler.validationError()
        }
        return value
    } catch {
        throw CompressedAudioAssembler.validationError()
    }
}

private func audioOptionalTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64? {
    guard time.isValid else { return nil }
    return try audioExactTicks(time, timeBase: timeBase)
}

private func audioOptionalDurationTicks(
    _ time: CMTime,
    timeBase: MediaRational
) throws -> Int64? {
    guard let value = try audioOptionalTicks(time, timeBase: timeBase), value >= 0 else {
        if !time.isValid { return nil }
        throw CompressedAudioAssembler.validationError()
    }
    return value
}
