// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct WriterBoundaryState: Sendable {
    let isSafeBoundary: Bool
    let nextNativeSequence: Int

    /// The policy sees the sequence the incoming sample would enter, including
    /// a real flush of the current segment. An empty successor performs no flush.
    static func beforeAppend(isSafeBoundary: Bool, currentNativeSequence: Int,
                             hasCurrentSegment: Bool) throws -> Self {
        guard HLSWriterSequencePolicy.supportedRange.contains(currentNativeSequence) else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        let entering = currentNativeSequence.addingReportingOverflow(
            isSafeBoundary && hasCurrentSegment ? 1 : 0)
        guard !entering.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
        return Self(isSafeBoundary: isSafeBoundary, nextNativeSequence: entering.partialValue)
    }
}
struct WriterCapacitySnapshot: Sendable {
    var liveCount: Int
    var liveBytes: Int
    let hardCount: Int
    let hardBytes: Int
    let nextBoundaryReserveCount: Int
    let nextBoundaryReserveBytes: Int
    var pendingCallbacks: Int
    let callbackCapacity: Int
}
enum WriterContinuationDecision: Sendable, Equatable {
    case continueCurrent, rolloverAtBoundary, newGeneration, backpressure, rejectUnsupported
}
enum HLSWriterSequencePolicy {
    /// Conservative candidate only. Exact native endpoint tests are a release
    /// acceptance gate; UInt32.max is already known to wrap to mfhd 1 on Apple.
    static let supportedRange = 1...1_000_000
}
enum WriterContinuationPolicy {
    static func decide(boundary: WriterBoundaryState, capacity: WriterCapacitySnapshot,
                       formatChanged: Bool) -> WriterContinuationDecision {
        if formatChanged || boundary.nextNativeSequence > HLSWriterSequencePolicy.supportedRange.upperBound {
            return boundary.isSafeBoundary ? .newGeneration : .rejectUnsupported
        }
        guard HLSWriterSequencePolicy.supportedRange.contains(boundary.nextNativeSequence),
              capacity.liveCount >= 0, capacity.liveBytes >= 0,
              capacity.nextBoundaryReserveCount > 0, capacity.nextBoundaryReserveBytes > 0,
              capacity.nextBoundaryReserveCount <= capacity.hardCount,
              capacity.nextBoundaryReserveBytes <= capacity.hardBytes,
              capacity.pendingCallbacks >= 0, capacity.callbackCapacity > 0 else { return .rejectUnsupported }
        if capacity.pendingCallbacks >= capacity.callbackCapacity { return .backpressure }
        let lacks = capacity.liveCount > capacity.hardCount - capacity.nextBoundaryReserveCount
            || capacity.liveBytes > capacity.hardBytes - capacity.nextBoundaryReserveBytes
        if lacks { return boundary.isSafeBoundary ? .rolloverAtBoundary : .rejectUnsupported }
        return .continueCurrent
    }
}
struct WriterBoundaryReserve: Sendable, Equatable {
    let segmentInputCount: Int
    let inputCount: Int
    let inputBytes: Int
    let pendingOutputCallbacks: Int
    init(samplesPerSecond: Int, samplesPerAccessUnit: Int, maximumBoundarySeconds: Int,
         delayedPreviousInputs: Int, pendingPumpInputs: Int, interleavedInputs: Int,
         maximumInputBytes: Int, pendingOutputCallbacks: Int) throws {
        guard samplesPerSecond > 0, samplesPerAccessUnit > 0, (1...60).contains(maximumBoundarySeconds),
              delayedPreviousInputs >= 0, pendingPumpInputs >= 0, interleavedInputs >= 0,
              maximumInputBytes > 0, pendingOutputCallbacks >= 0 else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        let product = samplesPerSecond.multipliedReportingOverflow(by: maximumBoundarySeconds)
        let rounded = product.partialValue.addingReportingOverflow(samplesPerAccessUnit - 1)
        guard !product.overflow, !rounded.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
        segmentInputCount = rounded.partialValue / samplesPerAccessUnit
        var count = segmentInputCount
        for extra in [delayedPreviousInputs, pendingPumpInputs, interleavedInputs] {
            let next = count.addingReportingOverflow(extra)
            guard !next.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
            count = next.partialValue
        }
        let bytes = count.multipliedReportingOverflow(by: maximumInputBytes)
        guard !bytes.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
        inputCount = count; inputBytes = bytes.partialValue
        self.pendingOutputCallbacks = pendingOutputCallbacks
    }
    func fits(inputCapacity: Int, evidenceCapacity: Int, inputByteCapacity: Int,
              outputCallbackCapacity: Int) -> Bool {
        inputCount <= inputCapacity && segmentInputCount <= evidenceCapacity
            && inputBytes <= inputByteCapacity && pendingOutputCallbacks <= outputCallbackCapacity
    }
}
struct WriterNativeFragmentFacts: Sendable, Equatable {
    let sequence: Int
    let decodeTime: UInt64
    static func read(_ data: Data) throws -> Self {
        try data.withUnsafeBytes { bytes in
            func number(_ start: Int, _ count: Int) throws -> UInt64 {
                guard start >= 0, count > 0, count <= 8, start <= bytes.count - count else {
                    throw SegmentedFMP4WriterFailure.systemFailure
                }
                return (start..<(start + count)).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[$1]) }
            }
            var sequence: Int?, decodeTime: UInt64?, visited = 0
            func scan(_ range: Range<Int>, depth: Int) throws {
                guard depth <= 3 else { throw SegmentedFMP4WriterFailure.systemFailure }
                var cursor = range.lowerBound
                while cursor < range.upperBound {
                    visited += 1
                    guard visited <= 128, range.upperBound - cursor >= 8 else { throw SegmentedFMP4WriterFailure.systemFailure }
                    let raw = try number(cursor, 4)
                    let type = try number(cursor + 4, 4)
                    let header = raw == 1 ? 16 : 8
                    let length = raw == 1 ? try number(cursor + 8, 8) : raw
                    guard let size = Int(exactly: length), size >= header, size <= range.upperBound - cursor else {
                        throw SegmentedFMP4WriterFailure.systemFailure
                    }
                    let payload = (cursor + header)..<(cursor + size)
                    if type == 0x6d6f6f66 || type == 0x74726166 { // moof, traf
                        try scan(payload, depth: depth + 1)
                    } else if type == 0x6d666864 { // mfhd
                        guard sequence == nil, payload.count == 8, try number(payload.lowerBound, 4) == 0,
                              let value = Int(exactly: try number(payload.lowerBound + 4, 4)),
                              HLSWriterSequencePolicy.supportedRange.contains(value) else { throw SegmentedFMP4WriterFailure.systemFailure }
                        sequence = value
                    } else if type == 0x74666474 { // tfdt
                        let version = try number(payload.lowerBound, 1)
                        guard decodeTime == nil, try number(payload.lowerBound + 1, 3) == 0,
                              (version == 0 && payload.count == 8) || (version == 1 && payload.count == 12) else {
                            throw SegmentedFMP4WriterFailure.systemFailure
                        }
                        decodeTime = try number(payload.lowerBound + 4, version == 0 ? 4 : 8)
                    }
                    cursor += size
                }
            }
            try scan(0..<bytes.count, depth: 0)
            guard let sequence, let decodeTime else { throw SegmentedFMP4WriterFailure.systemFailure }
            return Self(sequence: sequence, decodeTime: decodeTime)
        }
    }
}

/// Next legal cut + one bounded pump + two interleaved append slots. A retained
/// predecessor is counted in the physical input envelope, not blindly duplicated
/// in the packet pool; actual accepted native/frozen credits are inspected at flush.
struct AACWriterBoundaryProfile: Sendable, Equatable {
    let liveInputCapacity = 640
    let segmentEvidenceCapacity = 320
    let requiredInputCount: Int
    let nextBoundaryInputCount: Int
    let packetReservationBytes: Int
    let maximumNativePacketBytes: Int
    init(maximumBoundarySeconds: Int, maximumNativePacketBytes: Int) throws {
        let segment = try WriterBoundaryReserve(samplesPerSecond: 48_000, samplesPerAccessUnit: 1_024,
            maximumBoundarySeconds: maximumBoundarySeconds, delayedPreviousInputs: 0, pendingPumpInputs: 0,
            interleavedInputs: 0, maximumInputBytes: maximumNativePacketBytes, pendingOutputCallbacks: 3)
        let count = segment.segmentInputCount + 32 + 2
        let unit = try AACIncrementalEmission.allocationCharge(payloadBytes: maximumNativePacketBytes, packetCount: 1)
        let bytes = count.multipliedReportingOverflow(by: unit)
        guard !bytes.overflow, segment.segmentInputCount <= segmentEvidenceCapacity,
              segment.segmentInputCount * 2 + 34 <= liveInputCapacity,
              bytes.partialValue <= AACCalibrationWorkspace.aacPacketCapacity - 131_072 else {
            throw AACRenditionFailure.capacityExceeded
        }
        requiredInputCount = segment.segmentInputCount * 2 + 34
        nextBoundaryInputCount = count; packetReservationBytes = bytes.partialValue
        self.maximumNativePacketBytes = maximumNativePacketBytes
    }
}
struct AACWriterAdmissionSnapshot: Sendable, Equatable {
    let maximumNativePacketBytes: Int
    let maximumBoundarySeconds: Int
    let nextBoundaryInputCount: Int
    let nextBoundaryPacketBytes: Int
    let reservedPacketBytes: Int
}

/// Matches the store's authenticated long-GOP metadata domain. Checked before
/// native/source input claim, never by silently trimming an emitted fragment.
enum WriterDecodeCoveragePolicy {
    static func accepts(trackKind: SegmentedFMP4TrackKind, samplesPerSecond: Int,
                        samplesPerAccessUnit: Int, segmentInputCount: Int) -> Bool {
        guard samplesPerSecond > 0, samplesPerAccessUnit > 0, segmentInputCount > 0 else { return false }
        if segmentInputCount <= 256 { return true }
        switch trackKind {
        case .video:
            return segmentInputCount <= 384 && Int128(samplesPerSecond) <= 60 * Int128(samplesPerAccessUnit)
        case .aac:
            return segmentInputCount <= 320 && samplesPerSecond <= 48_000 && samplesPerAccessUnit == 1_024
        case .ac3, .eac3: return false
        }
    }
}
