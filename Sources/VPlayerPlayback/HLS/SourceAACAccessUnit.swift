// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

/// The ledger retains its reservation object, so reservation deinit cannot be the
/// release mechanism. This separate last-alias token explicitly returns credit.
final class HLSCompressedAudioApplicationReservation: @unchecked Sendable {
    private let ledger: HLSDeliveryApplicationChargeLedger
    private let reservation: PlaybackApplicationChargeReservation
    private init(ledger: HLSDeliveryApplicationChargeLedger, reservation: PlaybackApplicationChargeReservation) {
        self.ledger = ledger; self.reservation = reservation
    }
    static func reserve(bytes: Int, ledger: HLSDeliveryApplicationChargeLedger) throws -> HLSCompressedAudioApplicationReservation {
        let reservation = try ledger.reserve(allocationIdentity: UUID(), bytes: bytes)
        return HLSCompressedAudioApplicationReservation(ledger: ledger, reservation: reservation)
    }
    deinit { ledger.release(reservation) }
}

enum SourceAACFailure: Error, Sendable, Equatable {
    case unsupportedSource
    case sourceMismatch
    case timelineMismatch
    case renditionAlreadyBound
    case writerBindingMismatch
    case sourceAlreadyConsumed
}

/// One source-to-rendition authority. Physical writer windows will share this
/// object and the same native-input admission domain, rather than resetting it.
final class SourceAACRenditionAuthority: @unchecked Sendable {
    let identity = UUID()
    let initialBinding: FMP4WriterBinding
    let stream: CompressedAudioSourceStream
    private let applicationCharge: HLSCompressedAudioApplicationReservation

    fileprivate init(binding: FMP4WriterBinding, stream: CompressedAudioSourceStream,
                     charge: HLSCompressedAudioApplicationReservation) throws {
        initialBinding = binding; self.stream = stream; applicationCharge = charge
        guard stream.bindRendition(identity) else { throw SourceAACFailure.renditionAlreadyBound }
    }
    func acceptsInitialWriter(_ binding: FMP4WriterBinding) -> Bool {
        binding == initialBinding && stream.acceptsRendition(identity)
    }
}

struct SourceAACWriterConfiguration: @unchecked Sendable {
    let authority: SourceAACRenditionAuthority
    let sampleRate: Int32
    let channelCount: Int32
    let channelMask: UInt64
    let audioSpecificConfig: Data
    let priming: HLSSourceAudioPriming
    let sourceFormatHint: CMAudioFormatDescription
    let format: SystemCompressedAudioFormat
    let firstPresentationTime: ExactMediaTime
    let timelineIdentity: UUID
    let origin: MediaOriginReceipt

    init(first: HLSTimedAudioAccessUnit, source: HLSSourceAudioFacts, binding: FMP4WriterBinding,
         applicationLedger: HLSDeliveryApplicationChargeLedger = .shared) throws {
        guard HLSAudioProcessingPolicy.select(source: source,
                capabilities: .init(compressedAudioCodecs: [.aac]), hasVideo: false) == .passthrough(.aac) else {
            throw SourceAACFailure.unsupportedSource
        }
        guard first.validatesSourceMapping(), let proof = first.source.sourceProof,
              let timelineIdentity = first.sourceTimelineIdentity,
              let origin = first.sourceOriginReceipt,
              first.timing.presentationTimeStamp == origin.effectiveStart else {
            throw SourceAACFailure.timelineMismatch
        }
        guard proof.format.profileID == .aacLC, proof.format.codec == .aac,
              proof.format.framesPerPacket == 1_024, proof.format.sampleRate == source.sampleRate,
              proof.format.channelCount == source.channelCount,
              proof.sourceLayout.channelCount == source.channelCount,
              proof.sourceLayout.nativeMask == source.channelMask,
              proof.decoderConfiguration == source.decoderConfiguration else {
            throw SourceAACFailure.sourceMismatch
        }
        // Fixed authority/continuation bookkeeping is paid before its class/locks.
        let charge = try HLSCompressedAudioApplicationReservation.reserve(bytes: 16_384, ledger: applicationLedger)
        authority = try SourceAACRenditionAuthority(binding: binding, stream: proof.stream, charge: charge)
        sampleRate = source.sampleRate; channelCount = source.channelCount; channelMask = source.channelMask
        audioSpecificConfig = source.decoderConfiguration; priming = source.priming
        sourceFormatHint = proof.formatDescription; format = proof.format
        firstPresentationTime = first.timing.presentationTimeStamp
        self.timelineIdentity = timelineIdentity; self.origin = origin
    }

    func validates(_ unit: HLSTimedAudioAccessUnit) -> Bool {
        guard unit.validatesSourceMapping(), let proof = unit.source.sourceProof,
              proof.stream === authority.stream, authority.stream.acceptsRendition(authority.identity),
              unit.sourceTimelineIdentity == timelineIdentity, unit.sourceOriginReceipt == origin,
              proof.format == format, proof.decoderConfiguration == audioSpecificConfig,
              proof.sourceLayout.channelCount == channelCount,
              proof.sourceLayout.nativeMask == channelMask else { return false }
        return true
    }
}

/// A value wrapper over producer-owned bytes; callers cannot submit an arbitrary
/// Data payload, supply an encoder calibration receipt, or replace its mapping.
struct SourceAACAccessUnit: Sendable {
    let timed: HLSTimedAudioAccessUnit
    let configuration: SourceAACWriterConfiguration
    let binding: FMP4WriterBinding
    let payload: Data
    let payloadSHA256: Data
    let presentationStart: ExactMediaTime
    let duration: ExactMediaTime
    let sourceID: UInt64
    private let proof: CompressedAudioSourceProof

    init(timed: HLSTimedAudioAccessUnit, configuration: SourceAACWriterConfiguration,
         binding: FMP4WriterBinding) throws {
        guard configuration.authority.acceptsInitialWriter(binding) else {
            throw SourceAACFailure.writerBindingMismatch
        }
        guard configuration.validates(timed), let proof = timed.source.sourceProof,
              let duration = timed.timing.duration else { throw SourceAACFailure.sourceMismatch }
        self.timed = timed; self.configuration = configuration; self.binding = binding
        payload = timed.source.payload; payloadSHA256 = proof.payloadSHA256
        presentationStart = timed.timing.presentationTimeStamp; self.duration = duration
        sourceID = timed.source.id; self.proof = proof
    }
    func validates() -> Bool {
        configuration.authority.acceptsInitialWriter(binding) && configuration.validates(timed)
    }
    func claimForAppend() -> Bool {
        validates() && proof.claim(for: configuration.authority.identity)
    }
}
