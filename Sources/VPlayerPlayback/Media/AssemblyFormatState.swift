// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import CryptoKit

struct TimelineEpochID: Hashable, Sendable {
    let rawValue: UInt64
}

struct AssemblyEpochID: Hashable, Sendable {
    let timelineEpoch: TimelineEpochID
    let instanceToken: UInt64
}

struct AssemblyOperationID: Hashable, Sendable {
    let assemblyEpoch: AssemblyEpochID
    let bindingRevision: UInt64
}

/// Shared callback lease for one immutable audio/video assembler tuple. A
/// decoder-generation rebind invalidates native callbacks captured by the old
/// parser/framer without pretending that a new media timeline has begun.
final class AssemblyEpochBinding: @unchecked Sendable {
    private let lock = NSLock()
    private let epochID: AssemblyEpochID
    private var revision: UInt64 = 0
    private var active = true

    init(epochID: AssemblyEpochID) {
        self.epochID = epochID
    }

    static func standalone() -> AssemblyEpochBinding {
        AssemblyEpochBinding(epochID: AssemblyEpochID(
            timelineEpoch: TimelineEpochID(rawValue: 0),
            instanceToken: 0
        ))
    }

    func currentOperationID() -> AssemblyOperationID? {
        lock.withLock {
            guard active else { return nil }
            return AssemblyOperationID(
                assemblyEpoch: epochID,
                bindingRevision: revision
            )
        }
    }

    @discardableResult
    func rebind() -> AssemblyOperationID? {
        lock.withLock {
            guard active else { return nil }
            revision &+= 1
            return AssemblyOperationID(
                assemblyEpoch: epochID,
                bindingRevision: revision
            )
        }
    }

    func invalidate() {
        lock.withLock {
            guard active else { return }
            active = false
            revision &+= 1
        }
    }

    func accepts(_ operationID: AssemblyOperationID) -> Bool {
        lock.withLock {
            active
                && operationID.assemblyEpoch == epochID
                && operationID.bindingRevision == revision
        }
    }
}

final class AssemblyFormatState: @unchecked Sendable {
    private let lock = NSLock()
    let trackSet: DemuxTrackSet
    private var videoParameterSets: [Data]
    private var hlsVideoParameterSetOwner: HLSVideoParameterSetRetention?
    private var audioSystemFormat: AudioSystemFormatFingerprintComponent?
    private var videoPreferredTransfer: DemuxColorTransfer?
    private var videoSequenceEnded: Bool

    init(
        trackSet: DemuxTrackSet,
        videoParameterSets: [Data] = [],
        hlsVideoParameterSetOwner: HLSVideoParameterSetRetention? = nil,
        audioSystemFormat: AudioSystemFormatFingerprintComponent? = nil,
        videoPreferredTransfer: DemuxColorTransfer? = nil,
        videoSequenceEnded: Bool = false
    ) {
        self.trackSet = trackSet
        self.videoParameterSets = videoParameterSets
        self.hlsVideoParameterSetOwner = hlsVideoParameterSetOwner
        self.audioSystemFormat = audioSystemFormat
        self.videoPreferredTransfer = videoPreferredTransfer
        self.videoSequenceEnded = videoSequenceEnded
    }

    func commitVideoParameterSets(_ parameterSets: [Data]) {
        lock.withLock { videoParameterSets = parameterSets; hlsVideoParameterSetOwner = nil }
    }

    func commitHLSVideoParameterSets(_ owner: HLSVideoParameterSetRetention) {
        lock.withLock { videoParameterSets = []; hlsVideoParameterSetOwner = owner }
    }

    func commitAudioSystemFormat(_ format: AudioSystemFormatFingerprintComponent?) {
        lock.withLock { audioSystemFormat = format }
    }

    func commitVideoPreferredTransfer(_ transfer: DemuxColorTransfer?) {
        lock.withLock { videoPreferredTransfer = transfer }
    }

    func commitVideoSequenceEnded(_ ended: Bool) {
        lock.withLock { videoSequenceEnded = ended }
    }

    func snapshot() -> AssemblyFormatSnapshot {
        lock.withLock {
            AssemblyFormatSnapshot(
                videoParameterSets: videoParameterSets,
                hlsVideoParameterSetOwner: hlsVideoParameterSetOwner,
                audioSystemFormat: audioSystemFormat,
                videoPreferredTransfer: videoPreferredTransfer,
                videoSequenceEnded: videoSequenceEnded
            )
        }
    }

    func fingerprint() throws -> MediaFormatFingerprint {
        let snapshot = snapshot()
        let base: MediaFormatFingerprint
        if let owner = snapshot.hlsVideoParameterSetOwner {
            base = try MediaFormatFingerprint(
                trackSet: trackSet,
                hlsVideoParameterSetOwner: owner,
                audioSystemFormat: snapshot.audioSystemFormat
            )
        } else {
            base = try MediaFormatFingerprint(trackSet: trackSet,
                videoParameterSets: snapshot.videoParameterSets, audioSystemFormat: snapshot.audioSystemFormat)
        }
        guard let transfer = snapshot.videoPreferredTransfer else { return base }
        // 同一 SPS 下 ATC 变化也必须触发解码器重新配置。
        var hash = SHA256()
        hash.update(data: base.bytes)
        var value = transfer.rawValue.bigEndian
        withUnsafeBytes(of: &value) { hash.update(bufferPointer: $0) }
        return MediaFormatFingerprint(bytes: Data(hash.finalize()))
    }
}

struct AssemblyFormatSnapshot: Sendable {
    let videoParameterSets: [Data]
    let hlsVideoParameterSetOwner: HLSVideoParameterSetRetention?
    let audioSystemFormat: AudioSystemFormatFingerprintComponent?
    let videoPreferredTransfer: DemuxColorTransfer?
    let videoSequenceEnded: Bool

    init(videoParameterSets: [Data], hlsVideoParameterSetOwner: HLSVideoParameterSetRetention? = nil,
         audioSystemFormat: AudioSystemFormatFingerprintComponent?,
         videoPreferredTransfer: DemuxColorTransfer? = nil,
         videoSequenceEnded: Bool = false) {
        self.videoParameterSets = videoParameterSets
        self.hlsVideoParameterSetOwner = hlsVideoParameterSetOwner
        self.audioSystemFormat = audioSystemFormat
        self.videoPreferredTransfer = videoPreferredTransfer
        self.videoSequenceEnded = videoSequenceEnded
    }
}
