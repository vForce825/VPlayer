// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Writer-lane value evidence only. No sample, block, input lease, or release
/// closure belongs here. A verified callback retires only its exact sequence.
final class WriterSegmentEvidence {
    struct Sample: @unchecked Sendable {
        let identity: SegmentBoundarySampleIdentity
        let pts: ExactMediaTime
        let dts: ExactMediaTime?
        let duration: ExactMediaTime
        let projectedBytes: Int
        fileprivate let metadataLease: HLSDataPlaneAdmission.Lease
    }
    private let observation: HLSWriterAcceptanceProbe.Rendition?
    private let sampleCapacity: Int
    private let sequenceCapacity: Int
    private let metadataAdmission: HLSDataPlaneAdmission
    private var sequences: [UInt64: [Sample]] = [:]
    var sampleCount: Int { sequences.values.reduce(0) { $0 + $1.count } }
    var sequenceCount: Int { sequences.count }

    init(sampleCapacity: Int, sequenceCapacity: Int = 4,
         applicationLedger: HLSDeliveryApplicationChargeLedger = .shared,
         observation: HLSWriterAcceptanceProbe.Rendition? = nil) {
        precondition(sampleCapacity > 0 && sampleCapacity <= 1_024)
        precondition((1...4).contains(sequenceCapacity))
        self.observation = observation
        self.sampleCapacity = sampleCapacity
        self.sequenceCapacity = sequenceCapacity
        let count = sampleCapacity * sequenceCapacity
        metadataAdmission = HLSDataPlaneAdmission(capacity: count,
            maximumBytes: count * 768, applicationLedger: applicationLedger)
    }

    /// A paid slot carried by the append transaction. Dropping it rolls back
    /// only its metadata charge; it never owns native input or a writer.
    final class Reservation: @unchecked Sendable {
        let sequence: UInt64
        fileprivate var sample: Sample?
        fileprivate init(sequence: UInt64, sample: Sample) {
            self.sequence = sequence
            self.sample = sample
        }
    }

    func reserve(sequence: UInt64, sample: SegmentBoundarySampleIdentity,
                 pts: ExactMediaTime, dts: ExactMediaTime?, duration: ExactMediaTime,
                 projectedBytes: Int) throws -> Reservation {
        guard projectedBytes > 0, duration.value > 0,
              (sequences[sequence]?.count ?? 0) < sampleCapacity,
              sequences[sequence] != nil || sequences.count < sequenceCapacity,
              let lease = metadataAdmission.acquire(bytes: 768) else {
            throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
        }
        return Reservation(sequence: sequence, sample: .init(identity: sample, pts: pts,
            dts: dts, duration: duration, projectedBytes: projectedBytes, metadataLease: lease))
    }

    /// Writer lane admits at most one append transaction at a time. No allocation
    /// admission happens after native append; only this already-paid value moves.
    func commit(_ reservation: Reservation) throws {
        guard let sample = reservation.sample,
              (sequences[reservation.sequence]?.count ?? 0) < sampleCapacity,
              sequences[reservation.sequence] != nil || sequences.count < sequenceCapacity else {
            throw SegmentedFMP4WriterFailure.inputEvidenceCapacityExceeded
        }
        reservation.sample = nil
        sequences[reservation.sequence, default: []].append(sample)
        observation?.evidenceChanged(by: 1)
    }

    func record(sequence: UInt64, sample: SegmentBoundarySampleIdentity,
                pts: ExactMediaTime, dts: ExactMediaTime?, duration: ExactMediaTime,
                projectedBytes: Int) throws {
        try commit(reserve(sequence: sequence, sample: sample, pts: pts, dts: dts,
            duration: duration, projectedBytes: projectedBytes))
    }

    func retireVerified(sequence: UInt64) throws {
        guard let retired = sequences.removeValue(forKey: sequence) else {
            throw SegmentedFMP4WriterFailure.boundaryMismatch
        }
        observation?.evidenceChanged(by: -retired.count)
    }

    /// Failed/cancelled evidence has no authority and cannot outlive this writer.
    /// This drops metadata only; physical input allocations are independent.
    func discardUnverified() {
        let count = sampleCount
        sequences.removeAll(keepingCapacity: false)
        observation?.evidenceChanged(by: -count)
    }

    deinit { discardUnverified() }
}
