// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

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
    private var audioSystemFormat: AudioSystemFormatFingerprintComponent?

    init(
        trackSet: DemuxTrackSet,
        videoParameterSets: [Data] = [],
        audioSystemFormat: AudioSystemFormatFingerprintComponent? = nil
    ) {
        self.trackSet = trackSet
        self.videoParameterSets = videoParameterSets
        self.audioSystemFormat = audioSystemFormat
    }

    func commitVideoParameterSets(_ parameterSets: [Data]) {
        lock.withLock { videoParameterSets = parameterSets }
    }

    func commitAudioSystemFormat(_ format: AudioSystemFormatFingerprintComponent?) {
        lock.withLock { audioSystemFormat = format }
    }

    func fingerprint() throws -> MediaFormatFingerprint {
        let snapshot = lock.withLock { (videoParameterSets, audioSystemFormat) }
        return try MediaFormatFingerprint(
            trackSet: trackSet,
            videoParameterSets: snapshot.0,
            audioSystemFormat: snapshot.1
        )
    }
}
