// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

enum NativeHLSSelectionInvalidationReason: String, Sendable {
    case initial, unspecified, presentationSize, tracks, status, mediaSelection, accessLog, errorLog, failedToEnd
    case hdrEligibility, privateEOS, privateEOSRefresh
}

struct NativeHLSSelectionRevisionMismatch: Sendable {
    #if DEBUG
    let expected: UInt64
    let current: UInt64
    #endif
    let exhausted: Bool
    #if DEBUG
    let reason: NativeHLSSelectionInvalidationReason
    #endif
}

final class NativeHLSSelectionRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var exhausted = false
    private var endRefresh: (owner: ObjectIdentifier, wake: @Sendable () -> Void)?
    private var endpointToken: UUID?
    #if DEBUG
    private var lastInvalidationReason: NativeHLSSelectionInvalidationReason = .initial
    #endif
    var current: UInt64? { lock.withLock { exhausted ? nil : value } }
    func invalidate(reason: NativeHLSSelectionInvalidationReason = .unspecified) {
        lock.withLock { advanceLocked(reason: reason) }
    }
    private func advanceLocked(reason: NativeHLSSelectionInvalidationReason) {
        guard !exhausted else { return }
        #if DEBUG
        lastInvalidationReason = reason
        #endif
        if value == .max { exhausted = true } else { value += 1 }
    }
    func installEndRefresh(owner: ObjectIdentifier, wake: @escaping @Sendable () -> Void) {
        lock.withLock { endRefresh = (owner, wake) }
    }
    func clearEndRefresh(owner: ObjectIdentifier) {
        lock.withLock { if endRefresh?.owner == owner { endRefresh = nil } }
    }
    func installEndpoint(token: UUID) { lock.withLock { endpointToken = token } }
    func clearEndpoint(token: UUID) { lock.withLock { if endpointToken == token { endpointToken = nil } } }
    func receiveNativeEnd(token: UUID) {
        let wake = lock.withLock { () -> (@Sendable () -> Void)? in
            guard endpointToken == token else { return nil }
            advanceLocked(reason: .privateEOS); return endRefresh?.wake
        }
        // Never hold the revision lock while offering work to the observation owner.
        wake?()
    }
    func matches(_ revision: UInt64) -> Bool { mismatch(revision) == nil }
    func mismatch(_ revision: UInt64) -> NativeHLSSelectionRevisionMismatch? {
        lock.withLock {
            guard exhausted || value != revision else { return nil }
            #if DEBUG
            return .init(expected: revision, current: value, exhausted: exhausted, reason: lastInvalidationReason)
            #else
            return .init(exhausted: exhausted)
            #endif
        }
    }
}

enum NativeHLSQuantumValidationFailure: String, Sendable {
    case revision, logicalItem, physicalItem, source, trackCount, videoCount, videoAsset, videoTrack, videoAssetIdentity, visualSelection
}

struct NativeHLSQuantumValidationRejection: Sendable {
    let cause: NativeHLSQuantumValidationFailure
    var revision: NativeHLSSelectionRevisionMismatch?
    var sdkIdentity: NativeHLSQuantumSDKIdentityComparison?
}

/// Only a successful absent SDK group and an owned graph without alternate
/// visual declarations permit presentation-wrapper renewal. Failure is unknown.
enum NativeHLSVisualSelectionEvidence: UInt8, Sendable, CaseIterable {
    case unknown = 0, absent = 1, present = 2, sourceAlternates = 3
    static func classify(sourceHasNoAlternates: Bool, groupLoaded: Bool, groupPresent: Bool) -> Self {
        guard sourceHasNoAlternates else { return .sourceAlternates }
        guard groupLoaded else { return .unknown }
        return groupPresent ? .present : .absent
    }
    static func sourceHasNoAlternates(in graph: HLSManifestGraph) -> Bool {
        guard !graph.documents.isEmpty, graph.document(for: graph.rootURL) != nil else { return false }
        return graph.documents.values.allSatisfy { document in
            !document.renditions.contains { $0.attributes["TYPE"] == "VIDEO" } &&
                (document.variants + document.iframeVariants).allSatisfy { $0.attributes["VIDEO"] == nil }
        }
    }
}

/// Both equalities come from the same already-captured SDK objects. Bit zero is
/// the presentation wrapper; bit one is the exact retained media-track object.
struct NativeHLSQuantumSDKIdentityComparison: Sendable, Equatable {
    let equalFields: UInt8
    let visualSelection: NativeHLSVisualSelectionEvidence
    var usesWrapperRenewal: Bool { equalFields == 2 && visualSelection == .absent }
    func failure(allowingWrapperRenewal: Bool) -> NativeHLSQuantumValidationFailure? {
        guard equalFields & 1 != 0 || (allowingWrapperRenewal && usesWrapperRenewal) else { return .videoTrack }
        guard equalFields & 2 != 0 else { return .videoAssetIdentity }
        return nil
    }
    func permitsPendingPause(isReady: Bool, errorFree: Bool) -> Bool {
        failure(allowingWrapperRenewal: true) == nil && (!usesWrapperRenewal || (isReady && errorFree))
    }
}

struct NativeHLSQuantumValidationResult: Sendable {
    let rejection: NativeHLSQuantumValidationRejection?
    var sdkIdentity: NativeHLSQuantumSDKIdentityComparison?
}

/// A restriction on one existing private-EOS window, never a completion proof.
/// Once used, wrapper renewal cannot fall back to an ineligible exact wrapper.
struct NativeHLSQuantumWindow: Sendable {
    private(set) var requiresVisualAbsence = false
    mutating func recordWrapperRenewal(_ used: Bool) { requiresVisualAbsence = requiresVisualAbsence || used }
    func permits(_ evidence: NativeHLSVisualSelectionEvidence?) -> Bool { !requiresVisualAbsence || evidence == .absent }
    mutating func reset() { requiresVisualAbsence = false }
}

/// Only a non-exhausted revision supersession after every terminal installation
/// guard passes may use the remaining attempts of the original snapshot operation.
struct NativeHLSQuantumRevisionSuperseded: Error, Sendable {}

/// Presence bits: prior=1, current=2. Equality bits, in order: logical item,
/// physical item, video track, video asset, source owner, revision owner,
/// video facts, period, duration. Only immutable receipt fields are compared.
struct NativeHLSQuantumBindingComparison: Sendable, Equatable {
    static let allFields: UInt16 = 0x1FF
    let presence: UInt8
    let equalFields: UInt16
    /// Two bits each: prior, then current NativeHLSVisualSelectionEvidence.
    let visualSelections: UInt8
    init(presence: UInt8, equalFields: UInt16, visualSelections: UInt8 = 0) {
        self.presence = presence; self.equalFields = equalFields; self.visualSelections = visualSelections
    }
    var matches: Bool { presence == 0 || (presence == 3 && equalFields == Self.allFields) }
    var usesWrapperRenewal: Bool { presence == 3 && equalFields == (Self.allFields ^ (1 << 2)) && visualSelections == 5 }
    var matchesPendingWindow: Bool { matches || usesWrapperRenewal }
}

/// Selected SDK/configuration timing evidence, not proof that every final sample rendered.
/// Its allocation and aliases remain covered by the selected snapshot's charge.
final class NativeHLSFinalPresentationQuantum: @unchecked Sendable {
    let period: ExactMediaTime
    let duration: ExactMediaTime
    let visualSelection: NativeHLSVisualSelectionEvidence
    private let item: AVPlayerItemInstanceIdentity
    private let physicalItem: ObjectIdentifier
    // Object identity is valid only while the instance lives. Retain the exact
    // two inspected SDK objects with this already-charged receipt, not an array
    // of tracks, the driver, or its callback leases.
    private let videoTrack: AVPlayerItemTrack
    private let videoAsset: AVAssetTrack
    private let source: HLSOwnedSourcePlan
    private let video: HLSVideoFacts
    private let revision: UInt64
    private let selectionRevision: NativeHLSSelectionRevision
    private let retention: HLSApplicationLifetimeCharge
    fileprivate init(period: ExactMediaTime, duration: ExactMediaTime, item: AVPlayerItemInstanceIdentity,
        physicalItem: ObjectIdentifier, videoTrack: AVPlayerItemTrack, videoAsset: AVAssetTrack,
        source: HLSOwnedSourcePlan, video: HLSVideoFacts, revision: UInt64,
        selectionRevision: NativeHLSSelectionRevision, retention: HLSApplicationLifetimeCharge,
        visualSelection: NativeHLSVisualSelectionEvidence) {
        self.period = period; self.duration = duration; self.item = item; self.physicalItem = physicalItem
        self.videoTrack = videoTrack; self.videoAsset = videoAsset; self.source = source; self.retention = retention
        self.video = video; self.revision = revision; self.selectionRevision = selectionRevision
        self.visualSelection = visualSelection
    }
    @MainActor func isCurrent(item identity: AVPlayerItemInstanceIdentity, physical: AVPlayerItem) -> Bool {
        validationFailure(item: identity, physical: physical, requiresFreshness: true) == nil
    }
    @MainActor func hasCurrentIdentity(item identity: AVPlayerItemInstanceIdentity, physical: AVPlayerItem) -> Bool {
        validationFailure(item: identity, physical: physical, requiresFreshness: false) == nil
    }
    func revisionMismatch() -> NativeHLSSelectionRevisionMismatch? { selectionRevision.mismatch(revision) }
    @MainActor func validationFailure(item identity: AVPlayerItemInstanceIdentity, physical: AVPlayerItem,
                                     requiresFreshness: Bool) -> NativeHLSQuantumValidationRejection? {
        validation(item: identity, physical: physical, requiresFreshness: requiresFreshness).rejection
    }
    /// Installation and final confirmation always use exact current SDK objects.
    /// Only private ingress/pending-pause may defer a wrapper-only difference.
    @MainActor func validation(item identity: AVPlayerItemInstanceIdentity, physical: AVPlayerItem,
                              requiresFreshness: Bool, allowingWrapperRenewal: Bool = false) -> NativeHLSQuantumValidationResult {
        func reject(_ cause: NativeHLSQuantumValidationFailure,
                    revision: NativeHLSSelectionRevisionMismatch? = nil,
                    sdkIdentity: NativeHLSQuantumSDKIdentityComparison? = nil) -> NativeHLSQuantumValidationResult {
            .init(rejection: .init(cause: cause, revision: revision, sdkIdentity: sdkIdentity), sdkIdentity: sdkIdentity)
        }
        if requiresFreshness, let mismatch = selectionRevision.mismatch(revision) {
            return reject(.revision, revision: mismatch)
        }
        guard identity == item else { return reject(.logicalItem) }
        guard ObjectIdentifier(physical) == physicalItem else { return reject(.physicalItem) }
        guard source.sourceIsCurrent else { return reject(.source) }
        let enabled = physical.tracks.filter(\.isEnabled)
        guard enabled.count <= 16 else { return reject(.trackCount) }
        let videos = enabled.filter { $0.assetTrack?.mediaType == .video }
        guard videos.count == 1, let track = videos.first else { return reject(.videoCount) }
        guard let asset = track.assetTrack else { return reject(.videoAsset) }
        let sdkIdentity = NativeHLSQuantumSDKIdentityComparison(
            equalFields: (track === videoTrack ? 1 : 0) | (asset === videoAsset ? 2 : 0), visualSelection: visualSelection)
        if let cause = sdkIdentity.failure(allowingWrapperRenewal: allowingWrapperRenewal && !requiresFreshness) {
            return reject(cause, sdkIdentity: sdkIdentity)
        }
        return .init(rejection: nil, sdkIdentity: sdkIdentity)
    }
    func hasSameBinding(as other: NativeHLSFinalPresentationQuantum) -> Bool {
        Self.compareBindings(prior: other, current: self).matches
    }
    static func compareBindings(prior: NativeHLSFinalPresentationQuantum?, current: NativeHLSFinalPresentationQuantum?) -> NativeHLSQuantumBindingComparison {
        let presence: UInt8 = (prior == nil ? 0 : 1) | (current == nil ? 0 : 2)
        let visualSelections = (prior?.visualSelection.rawValue ?? 0) | ((current?.visualSelection.rawValue ?? 0) << 2)
        guard let prior, let current else { return .init(presence: presence, equalFields: 0, visualSelections: visualSelections) }
        var equal: UInt16 = 0
        if current.item == prior.item { equal |= 1 << 0 }
        if current.physicalItem == prior.physicalItem { equal |= 1 << 1 }
        if current.videoTrack === prior.videoTrack { equal |= 1 << 2 }
        if current.videoAsset === prior.videoAsset { equal |= 1 << 3 }
        if current.source === prior.source { equal |= 1 << 4 }
        if current.selectionRevision === prior.selectionRevision { equal |= 1 << 5 }
        if current.video == prior.video { equal |= 1 << 6 }
        if current.period == prior.period { equal |= 1 << 7 }
        if current.duration == prior.duration { equal |= 1 << 8 }
        return .init(presence: presence, equalFields: equal, visualSelections: visualSelections)
    }
}

struct NativeHLSSelectionSnapshot: Sendable {
    let item: AVPlayerItemInstanceIdentity
    let physicalItem: ObjectIdentifier
    let audioSelection: ObjectIdentifier?
    let video: HLSVideoFacts?
    let audio: HLSSourceAudioFacts?
    let audioConfigurationDigest: Data?
    let observedFrameRate: Double?
    let duration: ExactMediaTime?
    let finalPresentationQuantum: NativeHLSFinalPresentationQuantum?
    private let sourceOwner: HLSOwnedSourcePlan
    private let retention: HLSApplicationLifetimeCharge
    init(item: AVPlayerItemInstanceIdentity, physicalItem: ObjectIdentifier, audioSelection: ObjectIdentifier?,
         video: HLSVideoFacts?, audio: HLSSourceAudioFacts?, audioConfigurationDigest: Data?, observedFrameRate: Double?,
         sourceOwner: HLSOwnedSourcePlan, retention: HLSApplicationLifetimeCharge, duration: ExactMediaTime? = nil,
         finalPresentationQuantum: NativeHLSFinalPresentationQuantum? = nil) {
        self.item = item; self.physicalItem = physicalItem; self.audioSelection = audioSelection
        self.video = video; self.audio = audio; self.audioConfigurationDigest = audioConfigurationDigest
        self.observedFrameRate = observedFrameRate; self.duration = duration; self.sourceOwner = sourceOwner; self.retention = retention
        self.finalPresentationQuantum = finalPresentationQuantum
    }
    var information: PlaybackMediaInformation? {
        guard let video, video.width > 0, video.height > 0, video.scan == .progressive else { return nil }
        return .init(width: video.width, height: video.height, scanMode: .progressive,
            sourceFrameRate: video.frameRate, outputFrameRate: observedFrameRate, isSmoothMotionEnhanced: false)
    }
    func permitsTransition(from prior: Self) -> Bool {
        guard item == prior.item, physicalItem == prior.physicalItem else { return false }
        // Changed same-selection compressed configuration with unchanged source
        // facts is a contradiction. Known alternate selections remain available.
        if audioSelection == prior.audioSelection, audio == prior.audio,
           audioConfigurationDigest != prior.audioConfigurationDigest { return false }
        return true
    }
}

@MainActor
protocol NativeHLSAssetInspecting: AnyObject {
    func snapshot(item: AVPlayerItemInstanceIdentity, source: HLSOwnedSourcePlan) async throws -> NativeHLSSelectionSnapshot
}

@MainActor
final class SystemNativeHLSAssetInspector: NativeHLSAssetInspecting {
    private let driver: SystemAVPlayerDriver
    init(driver: SystemAVPlayerDriver) { self.driver = driver }

    func snapshot(item identity: AVPlayerItemInstanceIdentity, source: HLSOwnedSourcePlan) async throws -> NativeHLSSelectionSnapshot {
        let temporary = try HLSApplicationLifetimeCharge(bytes: 2 * 1_024 * 1_024)
        let retained = try HLSApplicationLifetimeCharge(bytes: 8 * 1_024)
        let callback = try driver.reserveSDKCallbackLease(.logFetch)
        defer { withExtendedLifetime((temporary, callback)) {} }
        guard source.sourceIsCurrent, let item = driver.nativeCurrentItem(identity) else { throw HLSSourceError.staleResolution }
        guard let revision = driver.nativeSelectionRevision.current else { throw HLSSourceError.capacity }
        // Capture ALL identities before the first asynchronous SDK load. Selecting
        // new identities after loading old formats would manufacture a mixed seal.
        let selected = item.currentMediaSelection
        let presentationSize = item.presentationSize
        let tracks = item.tracks.filter(\.isEnabled)
        guard tracks.count <= 16 else { throw HLSSourceError.capacity }
        let trackIDs = tracks.map(ObjectIdentifier.init)
        let assets = tracks.map(\.assetTrack)
        let assetIDs = assets.map { $0.map(ObjectIdentifier.init) }
        var audioGroup: AVMediaSelectionGroup?, subtitleGroup: AVMediaSelectionGroup?, visualGroup: AVMediaSelectionGroup?
        func validate() throws {
            try Task.checkCancellation()
            guard source.sourceIsCurrent, driver.nativeCurrentItem(identity) === item else { throw HLSSourceError.staleResolution }
            guard driver.nativeSelectionRevision.matches(revision) else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
            guard item.presentationSize == presentationSize else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
            let current = item.tracks.filter(\.isEnabled)
            guard current.map(ObjectIdentifier.init) == trackIDs,
                  current.map({ $0.assetTrack.map(ObjectIdentifier.init) }) == assetIDs else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
            for group in [audioGroup, subtitleGroup, visualGroup].compactMap({ $0 }) {
                guard selected.selectedMediaOption(in: group).map(ObjectIdentifier.init) ==
                    item.currentMediaSelection.selectedMediaOption(in: group).map(ObjectIdentifier.init) else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
            }
        }
        audioGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        try validate()
        subtitleGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        try validate()
        var visualGroupLoaded = false
        do {
            visualGroup = try await item.asset.loadMediaSelectionGroup(for: .visual)
            visualGroupLoaded = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Unknown visual eligibility keeps exact-wrapper behavior. The same
            // validation below still propagates cancellation and stale ownership.
        }
        try validate()
        let sourceHasNoVisualAlternates: Bool
        if case let .hls(graph) = source.source.topology {
            sourceHasNoVisualAlternates = NativeHLSVisualSelectionEvidence.sourceHasNoAlternates(in: graph)
        } else { sourceHasNoVisualAlternates = false }
        let visualSelection = NativeHLSVisualSelectionEvidence.classify(sourceHasNoAlternates: sourceHasNoVisualAlternates,
            groupLoaded: visualGroupLoaded, groupPresent: visualGroup != nil)
        let selectedAudio = audioGroup.flatMap { selected.selectedMediaOption(in: $0) }
        let expectsAudio = selectedAudio != nil || source.facts.media.contains { !$0.audio.isEmpty }
        let expectsVideo = source.facts.media.contains { $0.video != nil }
        var video: HLSVideoFacts?, audio: HLSSourceAudioFacts?, audioDigest: Data?, observedRate: Double?
        var videoQuantum: (period: ExactMediaTime, track: AVPlayerItemTrack, asset: AVAssetTrack)?
        #if DEBUG
        var quantumDetail = "reason=no-selected-video"
        #endif
        for (index, asset) in assets.enumerated() {
            // A nil SDK track can be non-audio text. The final expected-audio
            // and expected-video guards still require real selected format proof.
            guard let asset else { continue }
            let type: AVMediaType = asset.mediaType
            try validate()
            if type != .video && type != .audio { continue }
            let formats = try await asset.load(.formatDescriptions)
            try validate()
            guard formats.count == 1, let format = formats.first else { throw HLSSourceError.incompleteEvidence }
            if type == .video {
                guard video == nil else { throw HLSSourceError.unsupportedMedia }
                let selectedVideo = try Self.videoEvidence(format, expected: source.facts)
                let actual = selectedVideo.facts
                let rate = try await asset.load(.nominalFrameRate)
                try validate()
                if rate.isFinite, rate > 0 {
                    if let expected = actual.frameRate {
                        guard abs(Double(rate) - Double(expected.num) / Double(expected.den)) <= 0.02 else { throw HLSSourceError.unsupportedMedia }
                    }
                    observedRate = Double(rate)
                }
                let minimum = try? await asset.load(.minFrameDuration)
                try validate()
                let decision = Self.presentationQuantumDecision(minimumFrameDuration: minimum,
                    selectedFixedFrameRate: selectedVideo.fixedFrameRate, video: actual, expected: source.facts)
                if let period = decision.period {
                    videoQuantum = (period, tracks[index], asset)
                }
                #if DEBUG
                quantumDetail = "reason=\(decision.reason) source-rate=\(actual.frameRate?.num ?? 0)/\(actual.frameRate?.den ?? 0) " +
                    "source-explicit-rate=\(actual.explicitSequenceFrameRate?.num ?? 0)/\(actual.explicitSequenceFrameRate?.den ?? 0) " +
                    "fixed-sps-rate=\(selectedVideo.fixedFrameRate?.num ?? 0)/\(selectedVideo.fixedFrameRate?.den ?? 0) " +
                    "sdk-nominal=\(rate) sdk-min=\(minimum?.value ?? 0)/\(minimum?.timescale ?? 0):\(minimum?.epoch ?? 0):\(minimum?.flags.rawValue ?? 0) " +
                    "sdk-min-loaded=\(minimum != nil) variants=\(source.facts.media.compactMap(\.video).count)"
                #endif
                video = actual
            } else {
                guard audio == nil else { throw HLSSourceError.unsupportedMedia }
                let actual = try Self.audioFacts(format, expected: source.facts)
                audio = actual.0; audioDigest = actual.1
            }
            // A second SDK read rejects configuration changes within this load
            // stack even when the selected track object and dimensions stay equal.
            let currentFormats = try await asset.load(.formatDescriptions)
            try validate()
            guard currentFormats.count == 1, let currentFormat = currentFormats.first,
                  CMFormatDescriptionEqual(format, otherFormatDescription: currentFormat) else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
        }
        guard !expectsAudio || audio != nil, !expectsVideo || video != nil else { throw HLSSourceError.incompleteEvidence }
        try validate()
        var duration: ExactMediaTime?
        if case let .hls(graph) = source.source.topology {
            let media = graph.orderedDocuments.filter { $0.kind == .media }
            let end = Data("#EXT-X-ENDLIST".utf8)
            let endCR = Data("#EXT-X-ENDLIST\r".utf8)
            if !media.isEmpty, media.allSatisfy({ $0.rawData.split(separator: 10).contains { Data($0) == end || Data($0) == endCR } }) {
                let time = try await item.asset.load(.duration)
                try validate()
                if let value = try? ExactMediaTime(time), value.value > 0 { duration = value }
            }
        }
        let quantum: NativeHLSFinalPresentationQuantum?
        if let duration, let videoQuantum, let video {
            quantum = .init(period: videoQuantum.period, duration: duration, item: identity,
                physicalItem: ObjectIdentifier(item), videoTrack: videoQuantum.track, videoAsset: videoQuantum.asset,
                source: source, video: video, revision: revision,
                selectionRevision: driver.nativeSelectionRevision, retention: retained, visualSelection: visualSelection)
        } else { quantum = nil }
        #if DEBUG
        print("NATIVE_HLS_QUANTUM item=\(identity.itemGeneration) present=\(quantum != nil) visual=\(visualSelection.rawValue) duration=\(duration?.value ?? 0)/\(duration?.timescale ?? 0) \(quantumDetail)")
        #endif
        return .init(item: identity, physicalItem: ObjectIdentifier(item), audioSelection: selectedAudio.map(ObjectIdentifier.init),
            video: video, audio: audio, audioConfigurationDigest: audioDigest, observedFrameRate: observedRate,
            sourceOwner: source, retention: retained, duration: duration, finalPresentationQuantum: quantum)
    }

    static func validatedPresentationQuantum(minimumFrameDuration: CMTime?, selectedFixedFrameRate: MediaRational? = nil,
        video: HLSVideoFacts, expected: HLSCompatibilityFacts) -> ExactMediaTime? {
        presentationQuantumDecision(minimumFrameDuration: minimumFrameDuration,
            selectedFixedFrameRate: selectedFixedFrameRate, video: video, expected: expected).period
    }

    private static func presentationQuantumDecision(minimumFrameDuration: CMTime?, selectedFixedFrameRate: MediaRational?,
        video: HLSVideoFacts, expected: HLSCompatibilityFacts) -> (period: ExactMediaTime?, reason: String) {
        guard expected.complete, video.parameterSetsValidated, video.scan == .progressive,
              let rate = video.frameRate, rate.num > 0, rate.den > 0 else { return (nil, "source-timing-incomplete") }
        let period = ExactMediaTime(value: Int64(rate.den), timescale: rate.num)
        let variants = expected.media.compactMap(\.video)
        guard !variants.isEmpty, variants.allSatisfy({ video in
            video.parameterSetsValidated && video.scan == .progressive && video.frameRate == rate
        }) else { return (nil, "variant-period-mismatch") }
        // Only absent/invalid is unknown. Zero, indefinite, epoch and numeric
        // contradictions cannot borrow a period from selected source timing.
        guard (minimumFrameDuration?.epoch ?? 0) == 0 else { return (nil, "sdk-minimum-contradiction") }
        if minimumFrameDuration?.isValid != true {
            guard video.codec == .h264, selectedFixedFrameRate == rate else {
                return (nil, "sdk-minimum-unknown-without-selected-fixed-sps")
            }
            guard video.explicitSequenceFrameRate == rate else { return (nil, "source-explicit-period-missing-or-mismatch") }
            guard variants.allSatisfy({ $0.codec == .h264 && $0.explicitSequenceFrameRate == rate }) else {
                return (nil, "variant-explicit-period-missing-or-mismatch")
            }
            return (period, "selected-fixed-h264-sps")
        }
        guard let minimumFrameDuration, let minimum = try? ExactMediaTime(minimumFrameDuration),
              minimum.value > 0, minimum == period else { return (nil, "sdk-minimum-contradiction") }
        return (period, "sdk-minimum")
    }

    /// H.264 fixed_frame_rate_flag plus progressive frame pictures provides an
    /// explicit source presentation period. Average/nominal rates, variable-rate
    /// SPS and HEVC POC timing alone do not. This parses only the already bounded,
    /// selected parameter sets whose complete digest is matched below.
    static func selectedFixedFrameRate(parameterSets: [Data], codec: VideoCodec) -> MediaRational? {
        guard codec == .h264, parameterSets.count <= HLSVideoConfigurationFingerprint.maximumParameterSets,
              parameterSets.allSatisfy({ !$0.isEmpty && $0.count <= HLSVideoConfigurationFingerprint.maximumBytes }),
              parameterSets.reduce(0, { $0 + $1.count }) <= HLSVideoConfigurationFingerprint.maximumBytes else { return nil }
        let sequence = parameterSets.filter { $0[0] & 31 == 7 }
        guard !sequence.isEmpty else { return nil }
        var rate: MediaRational?
        for sps in sequence {
            guard let format = try? VideoSequenceParameterSetInspector.sourceFormat(Array(sps), codec: codec),
                  format.progressiveSourceFlag == true, let fixed = format.frameRate,
                  rate == nil || rate == fixed else { return nil }
            rate = fixed
        }
        return rate
    }

    static func videoFacts(_ format: CMFormatDescription, expected: HLSCompatibilityFacts) throws -> HLSVideoFacts {
        try videoEvidence(format, expected: expected).facts
    }
    private static func videoEvidence(_ format: CMFormatDescription, expected: HLSCompatibilityFacts) throws
        -> (facts: HLSVideoFacts, fixedFrameRate: MediaRational?) {
        let codec: VideoCodec
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_H264, 0x61766333: codec = .h264
        case kCMVideoCodecType_HEVC, 0x68657631: codec = .hevc
        default: throw HLSSourceError.unsupportedMedia
        }
        var count = 0, nalLength: Int32 = 0
        func parameter(_ index: Int) throws -> Data {
            var pointer: UnsafePointer<UInt8>?, size = 0
            let status: OSStatus
            if codec == .h264 {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            } else {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            }
            guard status == noErr, let pointer, size > 0, size <= HLSVideoConfigurationFingerprint.maximumBytes,
                  count > 0, count <= HLSVideoConfigurationFingerprint.maximumParameterSets else { throw HLSSourceError.incompleteEvidence }
            return Data(bytes: pointer, count: size)
        }
        let first = try parameter(0)
        var sets = [first], bytes = first.count
        let originalCount = count
        for index in 1..<originalCount {
            let next = try parameter(index)
            guard count == originalCount, next.count <= HLSVideoConfigurationFingerprint.maximumBytes - bytes else { throw HLSSourceError.byteLimit }
            bytes += next.count; sets.append(next)
        }
        let digest = try HLSVideoConfigurationFingerprint.make(codec: codec, parameterSets: sets)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let appearance = try NativeHLSSelectedVideoAppearance(format: format)
        guard let matching = expected.media.compactMap({ media -> HLSVideoFacts? in
            guard let video = media.video, video.codec == codec, video.parameterSetsValidated, video.scan == .progressive,
                  video.configurationFingerprint == digest, video.width == dimensions.width, video.height == dimensions.height,
                  appearance.matches(video, container: media.container) else { return nil }
            return video
        }).first else { throw HLSSourceError.unsupportedMedia }
        if appearance.range == .pq || appearance.range == .hlg {
            guard AVPlayer.eligibleForHDRPlayback else { throw HLSSourceError.unsupportedMedia }
        }
        return (matching, selectedFixedFrameRate(parameterSets: sets, codec: codec))
    }
    static func audioFacts(_ format: CMFormatDescription, expected: HLSCompatibilityFacts) throws -> (HLSSourceAudioFacts, Data) {
        guard let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { throw HLSSourceError.incompleteEvidence }
        let asbd = pointer.pointee
        guard asbd.mSampleRate.isFinite, asbd.mSampleRate > 0, asbd.mSampleRate <= 192_000,
              asbd.mSampleRate.rounded() == asbd.mSampleRate, (1...8).contains(asbd.mChannelsPerFrame) else { throw HLSSourceError.unsupportedMedia }
        let codec: AudioCodec
        switch asbd.mFormatID {
        // Native AAC policy currently admits LC only. A HE decoder format cannot
        // borrow an LC cookie merely because all AAC variants share a family.
        case kAudioFormatMPEG4AAC: codec = .aac
        case kAudioFormatAC3: codec = .ac3
        case kAudioFormatEnhancedAC3: codec = .eac3
        default: throw HLSSourceError.unsupportedMedia
        }
        let positions = try CompressedAudioChannelPositions.bitmap(in: format)
        guard positions.nonzeroBitCount == asbd.mChannelsPerFrame else { throw HLSSourceError.incompleteEvidence }
        var size = 0
        let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size)
        guard size >= 0, size <= 64 * 1_024, size == 0 || cookie != nil else { throw HLSSourceError.byteLimit }
        let bytes = cookie.map { Data(bytes: $0, count: size) } ?? Data()
        let configurationIdentity: Data
        let matching: HLSSourceAudioFacts?
        if codec == .aac {
            let aac = try NativeAACDecoderConfiguration.LCIdentity(configuration: NativeAACDecoderConfiguration.extract(bytes))
            guard aac.sampleRate == Int32(asbd.mSampleRate), aac.channelCount == Int32(asbd.mChannelsPerFrame),
                  asbd.mFramesPerPacket == 0 || asbd.mFramesPerPacket == 1_024 else { throw HLSSourceError.unsupportedMedia }
            configurationIdentity = aac.canonicalBytes
            matching = expected.media.flatMap(\.audio).first {
                $0.codec == .aac && $0.profile == 1 && $0.formatValidated && $0.service == .independentMain &&
                    $0.sampleRate == Int32(asbd.mSampleRate) && $0.channelCount == Int32(asbd.mChannelsPerFrame) &&
                    $0.channelMask == UInt64(positions) &&
                    (try? NativeAACDecoderConfiguration.LCIdentity(configuration: $0.decoderConfiguration)) == aac
            }
        } else {
            let actual = try NativeDolbyAudioConfiguration.parse(cookie: bytes, codec: codec, sampleRate: Int32(asbd.mSampleRate))
            guard actual.channelCount == Int32(asbd.mChannelsPerFrame) else { throw HLSSourceError.unsupportedMedia }
            configurationIdentity = actual.canonicalBox
            matching = expected.media.flatMap(\.audio).first { actual.matches($0, observedChannelMask: UInt64(positions)) }
        }
        guard let matching else { throw HLSSourceError.unsupportedMedia }
        return (matching, Data(SHA256.hash(data: configurationIdentity)))
    }
}

/// Compare the current effective Core Media description, including container
/// color that need not be present in otherwise unchanged SPS/PPS/VPS bytes.
private struct NativeHLSSelectedVideoAppearance {
    let primaries: String
    let transfer: String
    let matrix: String
    let range: HLSVideoRange
    let sampleEntry: String

    init(format: CMFormatDescription) throws {
        func value(_ key: CFString) throws -> String {
            guard let raw = CMFormatDescriptionGetExtension(format, extensionKey: key) else { throw HLSSourceError.incompleteEvidence }
            guard let value = raw as? String, value.utf8.count <= 128 else { throw HLSSourceError.unsupportedMedia }
            return value
        }
        primaries = try value(kCMFormatDescriptionExtension_ColorPrimaries)
        transfer = try value(kCMFormatDescriptionExtension_TransferFunction)
        matrix = try value(kCMFormatDescriptionExtension_YCbCrMatrix)
        // Core Video may expose equivalent H.273 codes through one string.
        // Keep that representation local to comparison; never replace the
        // original source code points or configuration fingerprint.
        let rec601Transfer = CVTransferFunctionGetStringForIntegerCodePoint(6).map { $0.takeUnretainedValue() as String }
        if transfer == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String || transfer == rec601Transfer {
            range = .sdr
        } else if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String {
            range = .pq
        } else if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
            range = .hlg
        } else {
            throw HLSSourceError.unsupportedMedia
        }
        // Unknown alternate transfer declarations cannot be silently discarded
        // while inheriting preflight SDR. Only the exposed effective transfer
        // contract above is currently supported.
        guard CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_AlternativeTransferCharacteristics) == nil,
              CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ProtectedContentOriginalFormat) == nil else {
            throw HLSSourceError.unsupportedMedia
        }
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_H264: sampleEntry = "avc1"
        case 0x61766333: sampleEntry = "avc3"
        case kCMVideoCodecType_HEVC: sampleEntry = "hvc1"
        case 0x68657631: sampleEntry = "hev1"
        default: throw HLSSourceError.unsupportedMedia
        }
    }
    func matches(_ expected: HLSVideoFacts, container: HLSMediaFacts.Container) -> Bool {
        guard let sourcePrimaries = expected.colorPrimaries, let sourceTransfer = expected.colorTransfer,
              let sourceMatrix = expected.colorMatrix, expected.videoRange == range,
              HLSVideoCapability.supportsNativeColor(expected),
              let mappedPrimaries = CVColorPrimariesGetStringForIntegerCodePoint(Int32(sourcePrimaries.rawValue)),
              let mappedTransfer = CVTransferFunctionGetStringForIntegerCodePoint(Int32(sourceTransfer.rawValue)),
              primaries == mappedPrimaries.takeUnretainedValue() as String,
              transfer == mappedTransfer.takeUnretainedValue() as String,
              matchesMatrix(sourceMatrix) else { return false }
        if let original = expected.sampleEntry {
            // No silent avc3/avc1 or hev1/hvc1 equivalence: normalized subtypes
            // lacking matching original-entry evidence fail this admission.
            return original == sampleEntry
        }
        // TS AVC has no ISO sample entry. Core Media exposes its actual AVC
        // decoding subtype; the full admitted parameter-set digest still matches.
        return container == .mpegTS && expected.codec == .h264 && sampleEntry == "avc1"
    }

    private func matchesMatrix(_ expected: DemuxColorMatrix) -> Bool {
        func matchesCode(_ code: DemuxColorMatrix) -> Bool {
            guard let mapped = CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(code.rawValue)) else { return false }
            return matrix == mapped.takeUnretainedValue() as String
        }
        // H.273 Table 4 defines identical coefficients for codes 5 and 6.
        // Core Video can preserve two labels rather than canonicalizing them.
        // This comparison runs only after the native color-family guard;
        // the original source code and fingerprint remain unchanged.
        if expected.isRec601 { return matchesCode(.bt470BG) || matchesCode(.smpte170M) }
        return matchesCode(expected)
    }
}

/// A bounded public AAC cookie may be raw ASC or an ES descriptor. Ignore only
/// transport bitrate fields; retain and validate the complete decoder config.
enum NativeAACDecoderConfiguration {
    /// Comparison only for source and selected formats already established as
    /// LC by audioFacts; never decoder extradata or a writer cookie. Plain ASC
    /// can allow a decoder to discover implicit SBR, so this identity alone
    /// does not establish payload semantics. Full ASC validation fixes AOT=LC,
    /// 1024 samples and all core/extension flags. Only the optional explicit
    /// SBR-absent extension has a shared identity within that admitted LC scope.
    struct LCIdentity: Equatable {
        let sampleRate: Int32
        let channelCount: Int32
        private let frequencyIndex: UInt8
        private let channelConfiguration: UInt8

        init(configuration: Data) throws {
            let parsed = try AudioSpecificConfig.parse(configuration)
            guard parsed.kind == .aacLC else { throw HLSSourceError.unsupportedMedia }
            sampleRate = parsed.outputSampleRate; channelCount = parsed.outputChannelCount
            // The complete parser above established these LC header positions.
            // Preserve indexed versus explicit frequency until equivalence on
            // the native decoder path is independently established.
            let start = configuration.startIndex
            frequencyIndex = ((configuration[start] & 7) << 1) | (configuration[start + 1] >> 7)
            channelConfiguration = (configuration[start + (frequencyIndex == 15 ? 4 : 1)] >> 3) & 15
        }

        var canonicalBytes: Data {
            var result = Data("VPlayer native AAC-LC identity v1".utf8)
            result.append(frequencyIndex)
            var rate = UInt32(sampleRate).bigEndian
            withUnsafeBytes(of: &rate) { result.append(contentsOf: $0) }
            result.append(channelConfiguration)
            return result
        }
    }

    static func extract(_ bytes: Data) throws -> Data {
        if (try? AudioSpecificConfig.parse(bytes)) != nil { return bytes }
        var offset = 0
        if bytes.count >= 12, bytes[4..<8] == Data("esds".utf8) { offset = 12 }
        func descriptor(_ tag: UInt8, end: Int) throws -> Range<Int> {
            guard offset < end, bytes[offset] == tag else { throw HLSSourceError.incompleteEvidence }
            offset += 1
            var count = 0, value = 0
            while true {
                guard offset < end, count < 4 else { throw HLSSourceError.incompleteEvidence }
                let byte = bytes[offset]; offset += 1; count += 1; value = value * 128 + Int(byte & 127)
                if byte & 128 == 0 { break }
            }
            guard value <= end - offset else { throw HLSSourceError.incompleteEvidence }
            return offset..<(offset + value)
        }
        let es = try descriptor(3, end: bytes.count)
        guard es.count >= 3, bytes[es.lowerBound + 2] == 0 else { throw HLSSourceError.incompleteEvidence }
        offset += 3
        let decoder = try descriptor(4, end: es.upperBound)
        guard decoder.count >= 13, bytes[decoder.lowerBound] == 0x40, bytes[decoder.lowerBound + 1] >> 2 == 5 else { throw HLSSourceError.incompleteEvidence }
        offset += 13
        let specific = try descriptor(5, end: decoder.upperBound)
        guard specific.count <= 64 else { throw HLSSourceError.byteLimit }
        let result = bytes.subdata(in: specific)
        _ = try AudioSpecificConfig.parse(result)
        return result
    }
}
