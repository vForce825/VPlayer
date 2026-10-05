// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// One native backing allocation's tail. The release body may own admitted
/// leases, but must never own a writer, sample, epoch, or encoded-output container.
/// Successful construction transfers this object to the block's FreeBlock context.
/// Deinit is rollback for a construction that never transferred the context.
final class WriterInputLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseBody: (@Sendable () -> Void)?
    private var capacityWakeup: WriterCapacityWakeup?
    private var nativeAdopted = false

    init(capacityWakeup: WriterCapacityWakeup? = nil,
         release: @escaping @Sendable () -> Void = {}) {
        self.capacityWakeup = capacityWakeup; releaseBody = release
    }
    func markNativeAdopted() { lock.withLock { nativeAdopted = true } }

    func releaseBacking() {
        let released = lock.withLock { () -> ((@Sendable () -> Void)?, WriterCapacityWakeup?) in
            defer { releaseBody = nil; capacityWakeup = nil }
            return (releaseBody, nativeAdopted ? capacityWakeup : nil)
        }
        released.0?()
        // Failed preflight copies are not native release edges and cannot cause
        // a self-waking retry loop. Signal only after real backing credit returns.
        released.1?.signal()
    }

    deinit { releaseBacking() }
}

/// Separate from segment evidence, callback backlog, and the writer's operation
/// lane. Admission never waits on a boundary that the same media worker must make.
/// The native block retains this service, not the writer, until its last alias dies.
final class WriterInputAdmission: @unchecked Sendable {
    static let metadataBytes = 4_096
    private let observation: HLSWriterAcceptanceProbe.Rendition?
    private let metadataAdmission: HLSDataPlaneAdmission
    private let lock = NSLock()
    private weak var capacityWakeup: WriterCapacityWakeup?
    let capacity: Int
    let maximumBytes: Int
    private var liveCount = 0
    private var liveBytes = 0
    private var cancelled = false
    private var admitted: UInt64 = 0
    private var released: UInt64 = 0
    var allocationCount: UInt64 { lock.withLock { admitted } }
    var releaseCount: UInt64 { lock.withLock { released } }

    init(capacity: Int, maximumBytes: Int,
         applicationLedger: HLSDeliveryApplicationChargeLedger = .shared,
         observation: HLSWriterAcceptanceProbe.Rendition? = nil) {
        precondition(capacity > 0 && capacity <= 1_024 && maximumBytes > 0)
        self.observation = observation
        self.capacity = capacity
        self.maximumBytes = maximumBytes
        metadataAdmission = HLSDataPlaneAdmission(capacity: capacity,
            maximumBytes: capacity * (Self.metadataBytes + 63 * 256),
            applicationLedger: applicationLedger)
    }

    func installCapacityWakeup(_ value: WriterCapacityWakeup) throws {
        try lock.withLock {
            guard capacityWakeup == nil || capacityWakeup === value else { throw SegmentedFMP4WriterFailure.illegalState }
            capacityWakeup = value
        }
    }
    func signalCapacityChange() { lock.withLock { capacityWakeup }?.signal() }

    var usage: HLSDataPlaneAdmissionUsage {
        lock.withLock { .init(count: liveCount, bytes: liveBytes, cancelled: cancelled) }
    }

    func admit(bytes: Int, sampleCount: Int = 1,
               release: @escaping @Sendable () -> Void = {}) throws -> WriterInputLifetime {
        let lease = try lock.withLock { () throws -> HLSDataPlaneAdmission.Lease in
            guard !cancelled, bytes > 0, bytes <= maximumBytes - liveBytes,
                  liveCount < capacity, (1...64).contains(sampleCount), admitted < UInt64.max else {
                throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
            }
            let metadata = Self.metadataBytes + (sampleCount - 1) * 256
            guard let lease = metadataAdmission.acquire(bytes: metadata, applicationBytes: metadata) else {
                throw SegmentedFMP4WriterFailure.terminalOwnershipCapacityExceeded
            }
            // Payload occupancy is a separate local bound. Its original allocator
            // still pays the full backing; this admission pays only the new wrapper.
            liveCount += 1
            liveBytes += bytes
            admitted += 1
            observation?.admitted(bytes: bytes)
            return lease
        }
        return WriterInputLifetime(capacityWakeup: lock.withLock { capacityWakeup }) { [self, lease] in
            release()
            lease.release()
            lock.withLock {
                precondition(liveCount > 0 && liveBytes >= bytes)
                liveCount -= 1
                liveBytes -= bytes
                released += 1
                observation?.released(bytes: bytes)
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        metadataAdmission.cancel()
        signalCapacityChange()
    }
}

/// Session-scoped, bounded diagnostics. It stores values for at most the existing
/// video + three audio renditions, never writer/sample/lease objects or histories.
struct HLSWriterAcceptanceSnapshot: Sendable, Equatable {
    var nativeWriterCount = 0
    var nativeAC3WriterCount = 0
    var nativeEAC3WriterCount = 0
    var liveInputCount = 0
    var liveInputBytes = 0
    var evidenceCount = 0
    var pendingCallbacks = 0
    var hardInputCount = 0
    var hardInputBytes = 0
    var hardEvidenceCount = 0
    var hardCallbackCount = 0
    /// Successful local input reservations, including rolled-back preflight.
    var acceptedInputCount: UInt64 = 0
    var releasedInputCount: UInt64 = 0
    var isComplete = true
}

struct HLSWriterRenditionAcceptanceSnapshot: Sendable, Equatable {
    let renditionIdentity: AudioRenditionIdentity
    var latestWriterIdentity: FMP4WriterIdentity
    var lastLogicalSequence: UInt64?
    var lastNativeSequence: Int?
    var usage: HLSWriterAcceptanceSnapshot
}

final class HLSWriterAcceptanceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var nativeWriterCount = 0
    private var nativeAC3WriterCount = 0
    private var nativeEAC3WriterCount = 0
    private var complete = true
    private var values: [AudioRenditionIdentity: HLSWriterRenditionAcceptanceSnapshot] = [:]

    var renditions: [HLSWriterRenditionAcceptanceSnapshot] {
        lock.withLock { Array(values.values) }
    }

    var snapshot: HLSWriterAcceptanceSnapshot {
        lock.withLock {
            var result = HLSWriterAcceptanceSnapshot()
            result.nativeWriterCount = nativeWriterCount
            result.nativeAC3WriterCount = nativeAC3WriterCount
            result.nativeEAC3WriterCount = nativeEAC3WriterCount
            result.isComplete = complete
            for value in values.values {
                let usage = value.usage
                result.liveInputCount += usage.liveInputCount
                result.liveInputBytes += usage.liveInputBytes
                result.evidenceCount += usage.evidenceCount
                result.pendingCallbacks += usage.pendingCallbacks
                result.hardInputCount += usage.hardInputCount
                result.hardInputBytes += usage.hardInputBytes
                result.hardEvidenceCount += usage.hardEvidenceCount
                result.hardCallbackCount += usage.hardCallbackCount
                result.acceptedInputCount += usage.acceptedInputCount
                result.releasedInputCount += usage.releasedInputCount
            }
            return result
        }
    }

    /// Called immediately after the actual AVAssetWriter allocation, including a
    /// construction that subsequently fails before start, binding or publication.
    func nativeWriterConstructed(trackKind: SegmentedFMP4TrackKind? = nil) {
        lock.withLock {
            nativeWriterCount += 1
            if trackKind == .ac3 { nativeAC3WriterCount += 1 }
            if trackKind == .eac3 { nativeEAC3WriterCount += 1 }
        }
    }

    func register(binding: FMP4WriterBinding, hardInputCount: Int, hardInputBytes: Int,
                  hardEvidenceCount: Int, hardCallbackCount: Int) -> Rendition? {
        lock.withLock {
            guard values[binding.renditionIdentity] != nil || values.count < 4 else {
                complete = false
                return nil
            }
            var value = values[binding.renditionIdentity] ?? .init(
                renditionIdentity: binding.renditionIdentity,
                latestWriterIdentity: binding.writerIdentity, usage: .init())
            value.latestWriterIdentity = binding.writerIdentity
            // Limits describe one physical writer's fixed rendition envelope;
            // live totals deliberately include predecessor aliases after rollover.
            value.usage.hardInputCount = hardInputCount
            value.usage.hardInputBytes = hardInputBytes
            value.usage.hardEvidenceCount = hardEvidenceCount
            value.usage.hardCallbackCount = hardCallbackCount
            values[binding.renditionIdentity] = value
            return Rendition(probe: self, binding: binding)
        }
    }

    private func update(_ binding: FMP4WriterBinding,
                        _ body: (inout HLSWriterRenditionAcceptanceSnapshot) -> Void) {
        lock.withLock {
            guard var value = values[binding.renditionIdentity] else { return }
            body(&value)
            values[binding.renditionIdentity] = value
        }
    }

    /// Retained by the native-tail admission independently of writer lifetime.
    final class Rendition: @unchecked Sendable {
        private let probe: HLSWriterAcceptanceProbe
        private let binding: FMP4WriterBinding
        fileprivate init(probe: HLSWriterAcceptanceProbe, binding: FMP4WriterBinding) {
            self.probe = probe
            self.binding = binding
        }
        func admitted(bytes: Int) {
            probe.update(binding) {
                $0.usage.liveInputCount += 1
                $0.usage.liveInputBytes += bytes
                $0.usage.acceptedInputCount += 1
            }
        }
        func released(bytes: Int) {
            probe.update(binding) {
                $0.usage.liveInputCount -= 1
                $0.usage.liveInputBytes -= bytes
                $0.usage.releasedInputCount += 1
            }
        }
        func evidenceChanged(by count: Int) {
            probe.update(binding) { $0.usage.evidenceCount += count }
        }
        func callbacksChanged(by count: Int) {
            probe.update(binding) { $0.usage.pendingCallbacks += count }
        }
        func observed(logicalSequence: UInt64?, nativeSequence: Int?) {
            probe.update(binding) {
                guard $0.latestWriterIdentity == binding.writerIdentity else { return }
                $0.lastLogicalSequence = logicalSequence
                $0.lastNativeSequence = nativeSequence
            }
        }
    }
}
