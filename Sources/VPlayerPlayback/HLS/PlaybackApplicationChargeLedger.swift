// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public final class PlaybackApplicationChargeReservation: @unchecked Sendable {
    public let reservationIdentity = UUID()
    public internal(set) var allocationIdentity: PlaybackApplicationAllocationIdentity
    public internal(set) var bytes: Int

    public init(allocationIdentity: PlaybackApplicationAllocationIdentity, bytes: Int) {
        self.allocationIdentity = allocationIdentity
        self.bytes = bytes
    }
}

public enum PlaybackApplicationAllocationIdentity: Sendable, Hashable {
    case stable(UUID)
    case object(ObjectIdentifier)
    case native(UInt)
    case owned(ObjectIdentifier, UInt8)
}

/// 在同一账本锁内核对一组 reservation 的当前归属，避免用进程级总量推断单一 owner。
public struct HLSDeliveryOwnedChargeSnapshot: Sendable, Equatable {
    public let reservationCount: Int
    public let registeredReservationCount: Int
    public let distinctAllocationCount: Int
    public let chargedBytes: Int

    public var allReservationsRegistered: Bool {
        registeredReservationCount == reservationCount
    }

    public init(
        reservationCount: Int,
        registeredReservationCount: Int,
        distinctAllocationCount: Int,
        chargedBytes: Int
    ) {
        self.reservationCount = reservationCount
        self.registeredReservationCount = registeredReservationCount
        self.distinctAllocationCount = distinctAllocationCount
        self.chargedBytes = chargedBytes
    }
}

/// 全局播放应用级资源计费总账。
/// 进程内唯一 PlaybackApplicationChargeLedger 跨 backend、session、generation、candidate、successor 与迟到 cleanup 持续存在。
/// 统一约束设计 11 全局及分层 reservation/charge ownership。
public final class PlaybackApplicationChargeLedger: @unchecked Sendable {
    public static let documentedApplicationSoftBytes = 981_184_512
    public static let documentedApplicationHardBytes = 1_266_647_040
    public static var softCapBytes: Int { documentedApplicationSoftBytes }
    public static var hardCapBytes: Int { documentedApplicationHardBytes }
    /// 全局账本对象、锁和既有容器的固定自举费用；resource bootstrap 另行 reserve。
    public static let sharedBookkeepingBytes = 2 * 1_024
    public static let shared = PlaybackApplicationChargeLedger(
        fixedBookkeepingChargeBytes: sharedBookkeepingBytes
    )

    public let identity = UUID()
    private let lock = NSLock()
    public let fixedBookkeepingChargeBytes: Int
    private var allocations: [PlaybackApplicationAllocationIdentity: (bytes: Int, references: Int)] = [:]
    private var reservations: [UUID: PlaybackApplicationChargeReservation] = [:]
    private var maximum: Int

    public init(fixedBookkeepingChargeBytes: Int = 0) {
        precondition(fixedBookkeepingChargeBytes >= 0)
        self.fixedBookkeepingChargeBytes = fixedBookkeepingChargeBytes
        maximum = fixedBookkeepingChargeBytes
    }

    public var chargedBytes: Int {
        lock.withLock {
            fixedBookkeepingChargeBytes + allocations.values.reduce(0) { $0 + $1.bytes }
        }
    }

    public var maximumChargedBytes: Int {
        lock.withLock { maximum }
    }

    public var shouldBackpressure: Bool {
        chargedBytes >= Self.documentedApplicationSoftBytes
    }

    /// 动态 reservation 全部释放后，单个新 allocation 永久可达到的最大值。
    public var maximumSingleReservationBytes: Int? {
        guard fixedBookkeepingChargeBytes < Self.documentedApplicationSoftBytes else {
            return nil
        }
        return max(0, Self.documentedApplicationHardBytes - fixedBookkeepingChargeBytes)
    }

    public func reserve(allocationIdentity: UUID, bytes: Int) throws
        -> PlaybackApplicationChargeReservation {
        try reserve(allocationIdentity: .stable(allocationIdentity), bytes: bytes)
    }

    public func reserve(
        allocationIdentity: PlaybackApplicationAllocationIdentity,
        bytes: Int
    ) throws -> PlaybackApplicationChargeReservation {
        try lock.withLock {
            guard bytes >= 0 else { throw LoopbackHTTPReservationError.hardCapacityExceeded }
            if let current = allocations[allocationIdentity] {
                guard current.bytes == bytes else { throw LoopbackHTTPReservationError.hardCapacityExceeded }
                allocations[allocationIdentity] = (current.bytes, current.references + 1)
            } else {
                let currentBytes = fixedBookkeepingChargeBytes + allocations.values.reduce(0) { $0 + $1.bytes }
                let projected = try HLSChecked.add(currentBytes, bytes)
                guard projected <= Self.documentedApplicationHardBytes else {
                    throw LoopbackHTTPReservationError.hardCapacityExceeded
                }
                guard currentBytes < Self.documentedApplicationSoftBytes else {
                    throw LoopbackHTTPReservationError.backpressure
                }
                allocations[allocationIdentity] = (bytes, 1)
                maximum = max(maximum, projected)
            }
            let reservation = PlaybackApplicationChargeReservation(
                allocationIdentity: allocationIdentity, bytes: bytes
            )
            reservations[reservation.reservationIdentity] = reservation
            return reservation
        }
    }

    public func release(_ reservation: PlaybackApplicationChargeReservation) {
        lock.withLock {
            guard reservations.removeValue(forKey: reservation.reservationIdentity) != nil,
                  let current = allocations[reservation.allocationIdentity] else { return }
            if current.references == 1 {
                allocations.removeValue(forKey: reservation.allocationIdentity)
            } else {
                allocations[reservation.allocationIdentity] = (current.bytes, current.references - 1)
            }
        }
    }

    public func rebind(
        _ reservation: PlaybackApplicationChargeReservation,
        to allocationIdentity: PlaybackApplicationAllocationIdentity
    ) throws {
        try lock.withLock {
            guard reservations[reservation.reservationIdentity] === reservation,
                  let old = allocations[reservation.allocationIdentity] else {
                throw LoopbackHTTPReservationError.hardCapacityExceeded
            }
            guard reservation.allocationIdentity != allocationIdentity else { return }
            if let current = allocations[allocationIdentity] {
                guard current.bytes == reservation.bytes else {
                    throw LoopbackHTTPReservationError.hardCapacityExceeded
                }
            } else if old.references > 1 {
                // 当旧 identity 还有其他 alias 且目标 identity 尚不存在时，
                // distinct bytes 将增加 reservation.bytes，必须检查容量并预拒绝超限
                let currentBytes = fixedBookkeepingChargeBytes + allocations.values.reduce(0) { $0 + $1.bytes }
                let projected = try HLSChecked.add(currentBytes, reservation.bytes)
                guard projected <= Self.documentedApplicationHardBytes else {
                    throw LoopbackHTTPReservationError.hardCapacityExceeded
                }
                guard currentBytes < Self.documentedApplicationSoftBytes else {
                    throw LoopbackHTTPReservationError.backpressure
                }
                maximum = max(maximum, projected)
            }
            if old.references == 1 {
                allocations.removeValue(forKey: reservation.allocationIdentity)
            } else {
                allocations[reservation.allocationIdentity] = (old.bytes, old.references - 1)
            }
            if let current = allocations[allocationIdentity] {
                allocations[allocationIdentity] = (current.bytes, current.references + 1)
            } else {
                allocations[allocationIdentity] = (reservation.bytes, 1)
            }
            reservation.allocationIdentity = allocationIdentity
        }
    }

    public func snapshot(
        ownedBy ownedReservations: [PlaybackApplicationChargeReservation]
    ) -> HLSDeliveryOwnedChargeSnapshot {
        lock.withLock {
            var registeredReservationCount = 0
            var allocationIdentities = Set<PlaybackApplicationAllocationIdentity>()
            for reservation in ownedReservations {
                guard reservations[reservation.reservationIdentity] === reservation else { continue }
                registeredReservationCount += 1
                allocationIdentities.insert(reservation.allocationIdentity)
            }
            let chargedBytes = allocationIdentities.reduce(0) { partial, identity in
                partial + (allocations[identity]?.bytes ?? 0)
            }
            return HLSDeliveryOwnedChargeSnapshot(
                reservationCount: ownedReservations.count,
                registeredReservationCount: registeredReservationCount,
                distinctAllocationCount: allocationIdentities.count,
                chargedBytes: chargedBytes
            )
        }
    }
}

public typealias HLSDeliveryApplicationChargeLedger = PlaybackApplicationChargeLedger

// MARK: - 设计 11 封闭容量包络推导与参数配置

public struct PlaybackCapacityEnvelope: Sendable, Equatable {
    public struct QueueLimit: Sendable, Equatable {
        public let softItems: Int
        public let hardItems: Int
        public let softBytes: Int
        public let hardBytes: Int
    }

    public struct SurfacePoolLimit: Sendable, Equatable {
        public let softSurfaces: Int
        public let hardSurfaces: Int
        public let softBytes: Int
        public let hardBytes: Int
    }

    public struct FrameQueueLimit: Sendable, Equatable {
        public let softFrames: Int
        public let hardFrames: Int
        public let softBytes: Int
        public let hardBytes: Int
    }

    public struct CalibrationLimit: Sendable, Equatable {
        public let workspaceCount: Int
        public let softBytes: Int
        public let hardBytes: Int
    }

    public struct LiveAACArtifactLimit: Sendable, Equatable {
        public let maximumArtifactCount: Int
        public let maxBytesPerArtifact: Int
        public let softBytes: Int
        public let hardBytes: Int
    }

    public struct WriterMediaLimit: Sendable, Equatable {
        public let softSegments: Int
        public let hardSegments: Int
        public let softBytes: Int
        public let hardBytes: Int
    }

    public struct SealedMediaStoreLimit: Sendable, Equatable {
        public let softSegmentsPerRendition: Int
        public let hardSegmentsPerRendition: Int
        public let softBytes: Int
        public let hardBytes: Int
        public let maxMapEvidenceItems: Int
        public let maxMapEvidenceBytesPerObject: Int
    }

    public struct SnapshotLimit: Sendable, Equatable {
        public let softSnapshots: Int
        public let hardSnapshots: Int
        public let softBytes: Int
        public let hardBytes: Int
    }

    public struct HTTPStagingLimit: Sendable, Equatable {
        public let softBytes: Int
        public let hardBytes: Int
    }

    public struct ControlLayerLimit: Sendable, Equatable {
        public let audioSessionEventBytes: Int
        public let systemEventSnapshotBytes: Int
        public let audioEventRelayBytes: Int
        public let presentationRelayBytes: Int
        public let hlsPlayerStateBytes: Int
        public let routeObservationBytes: Int
        public let controlTaskRecordsBytes: Int
        public var softBytes: Int {
            audioSessionEventBytes + systemEventSnapshotBytes + 12 * 1_024 + presentationRelayBytes + hlsPlayerStateBytes + routeObservationBytes + 48 * 1_024
        }
        public var hardBytes: Int {
            audioSessionEventBytes + systemEventSnapshotBytes + audioEventRelayBytes + presentationRelayBytes + hlsPlayerStateBytes + routeObservationBytes + controlTaskRecordsBytes
        }
    }

    public struct ResourceContextLimit: Sendable, Equatable {
        public let softBytes: Int
        public let hardBytes: Int
    }

    public let demuxQueueLimit: QueueLimit
    public let videoAssemblerQueueLimit: QueueLimit
    public let pixelSurfacePoolLimit: SurfacePoolLimit
    public let audioPCMQueueLimit: FrameQueueLimit
    public let audioAUQueueLimit: QueueLimit
    public let calibrationWorkspaceLimit: CalibrationLimit
    public let liveAACArtifactLimit: LiveAACArtifactLimit
    public let videoWriterMediaLimit: WriterMediaLimit
    public let audioWriterMediaLimit: WriterMediaLimit
    public let sealedMediaStoreLimit: SealedMediaStoreLimit
    public let playlistSnapshotLimit: SnapshotLimit
    public let httpStagingLimit: HTTPStagingLimit
    public let controlLayerLimit: ControlLayerLimit
    public let resourceContextLimit: ResourceContextLimit
    public let fixedBookkeepingBytes: Int

    public static let current = PlaybackCapacityEnvelope(
        demuxQueueLimit: QueueLimit(softItems: 192, hardItems: 256, softBytes: 48 * 1_048_576, hardBytes: 64 * 1_048_576),
        videoAssemblerQueueLimit: QueueLimit(softItems: 90, hardItems: 120, softBytes: 48 * 1_048_576, hardBytes: 64 * 1_048_576),
        pixelSurfacePoolLimit: SurfacePoolLimit(softSurfaces: 6, hardSurfaces: 8, softBytes: 192 * 1_048_576, hardBytes: 256 * 1_048_576),
        audioPCMQueueLimit: FrameQueueLimit(softFrames: 48_000, hardFrames: 96_000, softBytes: 4 * 1_048_576, hardBytes: 8 * 1_048_576),
        audioAUQueueLimit: QueueLimit(softItems: 96, hardItems: 192, softBytes: 2 * 1_048_576, hardBytes: 4 * 1_048_576),
        calibrationWorkspaceLimit: CalibrationLimit(workspaceCount: 1, softBytes: 3 * 1_048_576, hardBytes: 4 * 1_048_576),
        liveAACArtifactLimit: LiveAACArtifactLimit(maximumArtifactCount: 2, maxBytesPerArtifact: 512 * 1_024, softBytes: 1_048_576, hardBytes: 1_048_576),
        videoWriterMediaLimit: WriterMediaLimit(softSegments: 2, hardSegments: 3, softBytes: 48 * 1_048_576, hardBytes: 64 * 1_048_576),
        audioWriterMediaLimit: WriterMediaLimit(softSegments: 2, hardSegments: 3, softBytes: 4 * 1_048_576, hardBytes: 8 * 1_048_576),
        sealedMediaStoreLimit: SealedMediaStoreLimit(softSegmentsPerRendition: 42, hardSegmentsPerRendition: 48, softBytes: 560 * 1_048_576, hardBytes: 688 * 1_048_576, maxMapEvidenceItems: 256, maxMapEvidenceBytesPerObject: 32 * 1_024),
        playlistSnapshotLimit: SnapshotLimit(softSnapshots: 9, hardSnapshots: 10, softBytes: 5 * 1_048_576, hardBytes: 6 * 1_048_576),
        httpStagingLimit: HTTPStagingLimit(softBytes: 576 * 1_024, hardBytes: 768 * 1_024),
        controlLayerLimit: ControlLayerLimit(audioSessionEventBytes: 4 * 1_024, systemEventSnapshotBytes: 4 * 1_024, audioEventRelayBytes: 16 * 1_024, presentationRelayBytes: 2 * 1_024, hlsPlayerStateBytes: 2 * 1_024, routeObservationBytes: 4 * 1_024, controlTaskRecordsBytes: 64 * 1_024),
        resourceContextLimit: ResourceContextLimit(softBytes: 96 * 1_024, hardBytes: 128 * 1_024),
        fixedBookkeepingBytes: 2_048
    )

    /// 依设计 11：最多 3 条 audio rendition 逐项相加推导全局 soft cap
    public var softCapBytes: Int {
        demuxQueueLimit.softBytes
            + videoAssemblerQueueLimit.softBytes
            + pixelSurfacePoolLimit.softBytes
            + 3 * (audioPCMQueueLimit.softBytes + audioAUQueueLimit.softBytes + audioWriterMediaLimit.softBytes)
            + videoWriterMediaLimit.softBytes
            + sealedMediaStoreLimit.softBytes
            + playlistSnapshotLimit.softBytes
            + calibrationWorkspaceLimit.softBytes
            + liveAACArtifactLimit.softBytes
            + httpStagingLimit.softBytes
            + controlLayerLimit.softBytes
            + resourceContextLimit.softBytes
    }

    /// 依设计 11：最多 3 条 audio rendition 逐项相加推导全局 hard cap
    public var hardCapBytes: Int {
        demuxQueueLimit.hardBytes
            + videoAssemblerQueueLimit.hardBytes
            + pixelSurfacePoolLimit.hardBytes
            + 3 * (audioPCMQueueLimit.hardBytes + audioAUQueueLimit.hardBytes + audioWriterMediaLimit.hardBytes)
            + videoWriterMediaLimit.hardBytes
            + sealedMediaStoreLimit.hardBytes
            + playlistSnapshotLimit.hardBytes
            + calibrationWorkspaceLimit.hardBytes
            + liveAACArtifactLimit.hardBytes
            + httpStagingLimit.hardBytes
            + controlLayerLimit.hardBytes
            + resourceContextLimit.hardBytes
    }
}
