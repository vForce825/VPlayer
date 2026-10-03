// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import Darwin
import MediaToolbox
import Synchronization

/// Feasibility evidence, NOT an endpoint oracle yet. A post-effects tap observes
/// processed software output. It does not prove acoustic rendering. In particular,
/// preroll can process frames that are played later or flushed; keep every record.
@MainActor
final class Task21HLSAudioOutputProbe {
    enum Phase: UInt32 { case installed, prepared, activationRequested, activationReturned, naturalEnd, retiring }
    enum Failure: Error { case existingMix, formatCreation, tapCreation(OSStatus), replacedMix, drainTimeout, unusable(String) }

    struct Marker {
        let phase: Phase
        let hostTicks: UInt64
        let rate: Float
        let itemTime: CMTime
    }

    struct Snapshot {
        let scope: String
        let physicalItemIdentity: ObjectIdentifier
        let records: [Task21HLSTapRecord]
        /// Three windows per record, each containing eight stereo frames. Only
        /// windowFrames entries in each window are valid; no reference PCM is used.
        let samples: [Float]
        let markers: [Marker]
        let firstFailure: UInt32
        let reservedRecordBytes: Int
        let reservedSampleBytes: Int

        /// Non-vacuous probe admission only. No end equality or total-frame claim.
        /// Native trace review must establish restart/preroll semantics first.
        func requireUsableRawEvidence() throws {
            guard firstFailure == 0 else { throw Failure.unusable("stickyFailure=\(firstFailure)") }
            guard records.first?.kind == .initialize, records.last?.kind == .finalize else {
                throw Failure.unusable("missing physical initialize/finalize")
            }
            let processes = records.filter { $0.kind == .process }
            guard processes.contains(where: { $0.frames > 0 }),
                  processes.contains(where: { $0.sourceFlags & kMTAudioProcessingTapFlag_EndOfStream != 0 }) else {
                throw Failure.unusable("missing nonempty source output or source end-of-stream flag")
            }
            guard markers.contains(where: { $0.phase == .naturalEnd }),
                  markers.contains(where: { $0.phase == .activationReturned && $0.rate > 0 }) else {
                throw Failure.unusable("missing normal activation/natural-EOS facts")
            }
            guard records.filter({ $0.kind == .prepare }).count
                    == records.filter({ $0.kind == .unprepare }).count else {
                throw Failure.unusable("unbalanced physical prepare/unprepare")
            }
            for record in processes where record.frames > 0 {
                guard record.assetRange.isValid, !record.assetRange.isEmpty,
                      record.assetRange.start.isNumeric, record.assetRange.duration.isNumeric else {
                    throw Failure.unusable("invalid asset range at callback \(record.ordinal)")
                }
            }
        }

        /// Separate local renderer feasibility, not the HLS endpoint gate.
        /// Apple's source-EOS flag describes asynchronous audio-queue stopping;
        /// it is not documented as identical to AVPlayerItem's end notification.
        /// Keep its absence explicit. Never crop or fit raw frames to file length.
        func requireLocalPCMCallbackFeasibility() throws {
            let processes = records.filter { $0.kind == .process }
            let sourceEOS = processes.contains { $0.sourceFlags & kMTAudioProcessingTapFlag_EndOfStream != 0 }
            print("LOCAL_PCM_CALLBACK_FACTS \(scope) sourceEOSObserved=\(sourceEOS) "
                + "sourceEOSRequired=false endpointOracle=false processCallbacks=\(processes.count) "
                + "rawFrameTotal=\(processes.reduce(0) { $0 + $1.frames })")
            guard firstFailure == 0 else { throw Failure.unusable("stickyFailure=\(firstFailure)") }
            guard records.first?.kind == .initialize, records.last?.kind == .finalize,
                  records.filter({ $0.kind == .initialize }).count == 1,
                  records.filter({ $0.kind == .finalize }).count == 1 else {
                throw Failure.unusable("missing unique physical initialize/finalize")
            }
            let preparations = records.filter { $0.kind == .prepare }
            guard !preparations.isEmpty,
                  preparations.count == records.filter({ $0.kind == .unprepare }).count,
                  processes.contains(where: { $0.frames > 0 }) else {
                throw Failure.unusable("missing prepared source frames or balanced unprepare")
            }
            guard markers.contains(where: { $0.phase == .naturalEnd }),
                  markers.contains(where: { $0.phase == .activationReturned && $0.rate > 0 }) else {
                throw Failure.unusable("missing normal activation/genuine item EOS")
            }
            for record in processes where record.frames > 0 {
                guard record.assetRange.isValid, !record.assetRange.isEmpty,
                      record.assetRange.start.isNumeric, record.assetRange.duration.isNumeric,
                      record.format.mFormatID == kAudioFormatLinearPCM,
                      record.format.mSampleRate == 48_000, record.format.mChannelsPerFrame == 2,
                      record.format.mBitsPerChannel == 32,
                      record.format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                    throw Failure.unusable("invalid local PCM format/range at callback \(record.ordinal)")
                }
            }
            // The sticky callback gate additionally verifies packing, interleave,
            // byte counts, preparation order and every source API status.
            guard samples.allSatisfy({ $0.isFinite }),
                  samples.contains(where: { abs($0) > 0.00001 }) else {
                throw Failure.unusable("missing finite nonzero local PCM window")
            }
        }

        /// Call only after detachAndDrain(), on the normal test actor. Every raw
        /// callback is printed, including rate-zero, restarts and zero-frame EOS.
        func log() {
            print("AAC_TAP_SUMMARY \(scope) physicalItem=\(physicalItemIdentity) records=\(records.count) "
                + "stickyFailure=\(firstFailure) testRecordBytes=\(reservedRecordBytes) testSampleBytes=\(reservedSampleBytes)")
            for marker in markers {
                print("AAC_TAP_MARK phase=\(marker.phase) ticks=\(marker.hostTicks) rate=\(marker.rate) itemTime=\(Self.time(marker.itemTime))")
            }
            var previousOutput: Task21HLSTapRecord?
            for record in records {
                let format = record.format
                print("AAC_TAP_RAW ordinal=\(record.ordinal) kind=\(record.kind) "
                    + "generation=\(record.formatGeneration) stream=\(record.streamGeneration) ticks=\(record.hostTicks) "
                    + "phase=\(record.phase) lastObservedRate=\(Float(bitPattern: record.rateBits)) "
                    + "requested=\(record.requestedFrames) frames=\(record.frames) maxFrames=\(record.maxFrames) "
                    + "inputFlags=\(record.inputFlags) sourceFlags=\(record.sourceFlags) status=\(record.status) "
                    + "assetStart=\(Self.time(record.assetRange.start)) assetDuration=\(Self.time(record.assetRange.duration)) "
                    + "assetEnd=\(Self.time(CMTimeRangeGetEnd(record.assetRange))) "
                    + "rate=\(format.mSampleRate) format=\(format.mFormatID) formatFlags=\(format.mFormatFlags) "
                    + "channels=\(format.mChannelsPerFrame) bits=\(format.mBitsPerChannel) "
                    + "bytesPerFrame=\(format.mBytesPerFrame) bytesPerPacket=\(format.mBytesPerPacket) framesPerPacket=\(format.mFramesPerPacket)")
                if record.kind == .process, record.frames > 0 {
                    let relation: String
                    if let previousOutput {
                        if previousOutput.formatGeneration != record.formatGeneration { relation = "new-prepare-generation" }
                        else if previousOutput.streamGeneration != record.streamGeneration { relation = "source-start-flag" }
                        else if !previousOutput.assetRange.isValid || !record.assetRange.isValid { relation = "invalid-range" }
                        else {
                            let comparison = CMTimeCompare(record.assetRange.start, CMTimeRangeGetEnd(previousOutput.assetRange))
                            relation = comparison == 0 ? "contiguous" : (comparison > 0 ? "gap" : "overlap-or-replay")
                        }
                    } else { relation = "first-nonempty" }
                    let frameDuration = CMTime(value: Int64(record.frames), timescale: 48_000)
                    print("AAC_TAP_SEQUENCE ordinal=\(record.ordinal) relation=\(relation) "
                        + "rangeDurationMatches48kFrames=\(CMTimeCompare(record.assetRange.duration, frameDuration) == 0)")
                    // No concatenation, rate-zero filtering, restart repair or
                    // inference that an observed overlap necessarily was a flush.
                    previousOutput = record
                }
                guard record.windowFrames > 0 else { continue }
                for window in 0..<3 {
                    let start = record.sampleOffset + window * Task21HLSTapStorage.samplesPerWindow
                    let end = start + record.windowFrames * 2
                    print("AAC_TAP_PCM ordinal=\(record.ordinal) window=\(window) "
                        + "sourceFrameOffset=\(record.windowStart(window)) samples=\(samples[start..<end])")
                }
            }
        }

        private static func time(_ time: CMTime) -> String {
            "\(time.value)/\(time.timescale):epoch\(time.epoch):flags\(time.flags.rawValue)"
        }
    }

    /// Normal-actor facts for diagnostic classification only; never gates HLS.
    private(set) var configurationStayedValid = true
    private let scope: String
    private let physicalItemIdentity: ObjectIdentifier
    private let tappedTrackID: CMPersistentTrackID
    private let state: Task21HLSTapStorage
    private var item: AVPlayerItem?
    /// AVPlayerItem copies the assigned mix. Track the installed copy weakly so
    /// ownership verification cannot itself retain the tap through finalization.
    private weak var installedMix: AVAudioMix?
    private var tap: MTAudioProcessingTap?
    private var rateObservation: NSKeyValueObservation?
    private var markers: [Marker] = []
    private var drained: Snapshot?

    private init(item: AVPlayerItem, scope: String, trackID: CMPersistentTrackID,
                 state: Task21HLSTapStorage, tap: MTAudioProcessingTap) {
        self.item = item
        self.scope = scope
        physicalItemIdentity = ObjectIdentifier(item)
        tappedTrackID = trackID
        self.state = state
        self.tap = tap
        markers.reserveCapacity(16)
    }

    static func attach(to item: AVPlayerItem, player: AVPlayer, scope: String) throws -> Task21HLSAudioOutputProbe {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = AVAudioMixInputParametersTrackID.mixID.rawValue
        return try attach(to: item, player: player, scope: scope, parameters: parameters)
    }

    /// Local-asset control only. All tap construction, callbacks and storage are
    /// identical to HLS; only ordinary asset-track association differs.
    static func attachLocalReference(to item: AVPlayerItem, player: AVPlayer, track: AVAssetTrack,
                                     scope: String) throws -> Task21HLSAudioOutputProbe {
        try attach(to: item, player: player, scope: scope,
                   parameters: AVMutableAudioMixInputParameters(track: track))
    }

    private static func attach(to item: AVPlayerItem, player: AVPlayer, scope: String,
                               parameters: AVMutableAudioMixInputParameters) throws -> Task21HLSAudioOutputProbe {
        guard player.currentItem === item, item.audioMix == nil else { throw Failure.existingMix }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                        channels: 2, interleaved: false) else { throw Failure.formatCreation }
        let state = Task21HLSTapStorage()
        // init retains clientInfo for the tap; finalize consumes that retain.
        // If creation fails before init, there is no extra ownership to release.
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(state).toOpaque(),
            init: task21TapInitialize, finalize: task21TapFinalize,
            prepare: task21TapPrepare, unprepare: task21TapUnprepare, process: task21TapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreateWithPreferredFormat(kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, format.formatDescription, &tap)
        guard status == noErr, let tap else { throw Failure.tapCreation(status) }
        let probe = Task21HLSAudioOutputProbe(item: item, scope: scope, trackID: parameters.trackID,
                                            state: state, tap: tap)
        probe.rateObservation = player.observe(\.rate, options: [.initial, .new]) { _, change in
            if let rate = change.newValue { state.observedRate.store(rate.bitPattern, ordering: .releasing) }
        }
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        probe.installedMix = item.audioMix
        probe.mark(.installed, player: player)
        return probe
    }

    /// These are main-actor observations, not a claim about instantaneous render
    /// rate inside a callback. A callback records the most recently observed rate.
    func mark(_ phase: Phase, player: AVPlayer) {
        state.phase.store(phase.rawValue, ordering: .releasing)
        guard markers.count < 16 else { state.fail(.markerOverflow); return }
        markers.append(Marker(phase: phase, hostTicks: mach_continuous_time(),
                              rate: player.rate, itemTime: player.currentTime()))
        logConfiguration(phase: phase, player: player)
    }

    private func logConfiguration(phase: Phase, player: AVPlayer) {
        // Read-only main-actor diagnostics. Never query AVFoundation from a tap
        // callback, and never infer audible output from any of these properties.
        let parameters = item?.audioMix?.inputParameters ?? []
        let mixTapCount = parameters.filter {
            $0.trackID == AVAudioMixInputParametersTrackID.mixID.rawValue
                && $0.audioTapProcessor === tap
        }.count
        let associatedTapCount = parameters.filter {
            $0.trackID == tappedTrackID && $0.audioTapProcessor === tap
        }.count
        let originalMixInstalled = installedMix != nil && item?.audioMix === installedMix
        configurationStayedValid = configurationStayedValid && player.currentItem === item
            && originalMixInstalled && parameters.count == 1 && associatedTapCount == 1
            && !player.isMuted && player.volume > 0 && !player.disconnectedFromSystemAudio
            && !player.isExternalPlaybackActive && player.status != .failed && item?.status != .failed
        print("AAC_TAP_SETUP \(scope) phase=\(phase) originalItemCurrent=\(player.currentItem === item) "
            + "originalMixInstalled=\(originalMixInstalled) parameters=\(parameters.count) mixTapCount=\(mixTapCount) "
            + "tappedTrackID=\(tappedTrackID) associatedTapCount=\(associatedTapCount) "
            + "playerMuted=\(player.isMuted) playerVolume=\(player.volume) rate=\(player.rate) "
            + "timeControl=\(player.timeControlStatus.rawValue) disconnected=\(player.disconnectedFromSystemAudio) "
            + "externalVideoPlayback=\(player.isExternalPlaybackActive)")
        Task21NativeAudioSessionReference.logRoute(stage: "tap-\(phase)")
    }

    /// Invoke AFTER normal Registry retirement has removed the physical item.
    /// Clearing audioMix alone is not the drain proof; actual finalize is.
    func detachAndDrain() async throws -> Snapshot {
        if let drained { return drained }
        var replacedMix = false
        do { try detachExactInstalledMix() }
        catch {
            replacedMix = true
            state.fail(.mixReplaced)
        }
        installedMix = nil
        rateObservation?.invalidate()
        rateObservation = nil
        // AVPlayerItem copies its mix. Releasing every fixture-owned tap alias is
        // essential, otherwise finalize could never be the physical drain barrier.
        tap = nil
        item = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !state.finalized.load(ordering: .acquiring), ContinuousClock.now < deadline {
            // Cancellation must not release storage ahead of the native callback.
            // Yield on the test actor; no callback ever creates or resumes a Task.
            await Task.yield()
        }
        guard state.finalized.load(ordering: .acquiring) else {
            // The tap's independent retain survives this failure until native
            // finalize. Never free a still-accessible raw callback pointer.
            // A replacement may still own this tap; report the ownership failure
            // rather than clearing it or concealing it behind a drain timeout.
            if replacedMix { throw Failure.replacedMix }
            throw Failure.drainTimeout
        }
        let snapshot = Snapshot(scope: scope, physicalItemIdentity: physicalItemIdentity,
            records: Array(UnsafeBufferPointer(start: state.records, count: state.count)),
            samples: Array(UnsafeBufferPointer(start: state.samples,
                count: state.count * Task21HLSTapStorage.samplesPerRecord)), markers: markers,
            firstFailure: state.firstFailure.load(ordering: .acquiring),
            reservedRecordBytes: Task21HLSTapStorage.capacity * MemoryLayout<Task21HLSTapRecord>.stride,
            reservedSampleBytes: Task21HLSTapStorage.capacity * Task21HLSTapStorage.samplesPerRecord * MemoryLayout<Float>.stride)
        drained = snapshot
        if replacedMix { throw Failure.replacedMix }
        return snapshot
    }

    private func detachExactInstalledMix() throws {
        // A synchronous helper bounds this temporary strong mix alias before the
        // drain wait. A different mix remains untouched even if it reuses our tap.
        guard let item, let currentMix = item.audioMix else {
            // Already cleared is not a drain proof; the caller still awaits the
            // physical finalize callback after dropping its own tap alias.
            return
        }
        guard currentMix === installedMix else { throw Failure.replacedMix }
        item.audioMix = nil
    }
}

struct Task21HLSTapRecord {
    enum Kind { case initialize, prepare, process, unprepare, finalize }
    var kind: Kind = .initialize
    var ordinal = 0
    var formatGeneration: UInt64 = 0
    var streamGeneration: UInt64 = 0
    var hostTicks: UInt64 = 0
    var phase: UInt32 = 0
    var rateBits: UInt32 = 0
    var format = AudioStreamBasicDescription()
    var maxFrames: CMItemCount = 0
    var requestedFrames: CMItemCount = 0
    var frames: CMItemCount = 0
    var inputFlags: MTAudioProcessingTapFlags = 0
    var sourceFlags: MTAudioProcessingTapFlags = 0
    var status: OSStatus = noErr
    /// Apple's GetSourceAudio contract: asset time, not host or AVPlayer clock.
    /// Mapping it to this fixture's writer source timeline remains a native check.
    var assetRange = CMTimeRange.invalid
    var sampleOffset = 0
    var windowFrames = 0

    func windowStart(_ index: Int) -> Int {
        switch index {
        case 0: return 0
        case 1: return max(0, (frames - windowFrames) / 2)
        default: return max(0, frames - windowFrames)
        }
    }
}

/// Test allocations deliberately live outside the production capped graph. All
/// callback slots and PCM windows are reserved before the tap is installed.
/// Atomics are only a nonblocking overlap guard and cross-thread publication;
/// there is no mutex, callback logging, dispatch, Array append or allocation.
private final class Task21HLSTapStorage: @unchecked Sendable {
    static let capacity = 2_048
    static let windowFrames = 8
    static let samplesPerWindow = windowFrames * 2
    static let samplesPerRecord = samplesPerWindow * 3
    enum Fault: UInt32 {
        case overlap = 1, recordOverflow, sourceError, unsupportedFormat, invalidFrames,
             invalidBuffers, processOutsidePreparation, unbalancedPreparation, markerOverflow, mixReplaced
    }
    let phase = Atomic<UInt32>(0)
    let observedRate = Atomic<UInt32>(0)
    let finalized = Atomic<Bool>(false)
    let firstFailure = Atomic<UInt32>(0)
    private let callbackBusy = Atomic<Bool>(false)
    let records = UnsafeMutablePointer<Task21HLSTapRecord>.allocate(capacity: Task21HLSTapStorage.capacity)
    let samples = UnsafeMutablePointer<Float>.allocate(
        capacity: Task21HLSTapStorage.capacity * Task21HLSTapStorage.samplesPerRecord)
    private(set) var count = 0
    private var generation: UInt64 = 0
    private var stream: UInt64 = 0
    private var format = AudioStreamBasicDescription()
    private var maxFrames: CMItemCount = 0
    private var prepared = false
    private var readablePCM = false

    init() {
        records.initialize(repeating: Task21HLSTapRecord(), count: Self.capacity)
        samples.initialize(repeating: 0, count: Self.capacity * Self.samplesPerRecord)
    }

    deinit {
        records.deinitialize(count: Self.capacity)
        records.deallocate()
        samples.deinitialize(count: Self.capacity * Self.samplesPerRecord)
        samples.deallocate()
    }

    func fail(_ fault: Fault) {
        _ = firstFailure.compareExchange(expected: 0, desired: fault.rawValue, ordering: .acquiringAndReleasing)
    }

    func enter() -> Bool {
        guard !callbackBusy.exchange(true, ordering: .acquiringAndReleasing) else { fail(.overlap); return false }
        return true
    }
    func leave() { callbackBusy.store(false, ordering: .releasing) }

    @discardableResult
    func append(_ kind: Task21HLSTapRecord.Kind) -> UnsafeMutablePointer<Task21HLSTapRecord>? {
        guard count < Self.capacity else { fail(.recordOverflow); return nil }
        let slot = records.advanced(by: count)
        slot.pointee = Task21HLSTapRecord()
        slot.pointee.kind = kind
        slot.pointee.ordinal = count
        slot.pointee.sampleOffset = count * Self.samplesPerRecord
        slot.pointee.formatGeneration = generation
        slot.pointee.streamGeneration = stream
        slot.pointee.hostTicks = mach_continuous_time()
        slot.pointee.phase = phase.load(ordering: .acquiring)
        slot.pointee.rateBits = observedRate.load(ordering: .acquiring)
        slot.pointee.format = format
        slot.pointee.maxFrames = maxFrames
        count += 1
        return slot
    }

    func prepare(maxFrames: CMItemCount, format: AudioStreamBasicDescription) {
        guard enter() else { return }
        defer { leave() }
        if prepared { fail(.unbalancedPreparation) }
        prepared = true
        generation += 1
        self.maxFrames = maxFrames
        self.format = format
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        readablePCM = format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate == 48_000
            && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsPacked != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mBytesPerFrame == (planar ? 4 : 8)
            && format.mFramesPerPacket == 1 && format.mBytesPerPacket == format.mBytesPerFrame
        if !readablePCM { fail(.unsupportedFormat) }
        append(.prepare)
    }

    func unprepare() {
        guard enter() else { return }
        defer { leave() }
        if !prepared { fail(.unbalancedPreparation) }
        append(.unprepare)
        prepared = false
    }

    func process(requested: CMItemCount, inputFlags: MTAudioProcessingTapFlags,
                 frames: CMItemCount, sourceFlags: MTAudioProcessingTapFlags, status: OSStatus,
                 range: CMTimeRange, buffers: UnsafeMutablePointer<AudioBufferList>) {
        // Called with the gate held across GetSourceAudio, not only across writes.
        if !prepared { fail(.processOutsidePreparation) }
        if status != noErr { fail(.sourceError) }
        if frames < 0 || frames > requested || requested > maxFrames { fail(.invalidFrames) }
        if sourceFlags & kMTAudioProcessingTapFlag_StartOfStream != 0 { stream += 1 }
        guard let slot = append(.process) else { return }
        slot.pointee.requestedFrames = requested
        slot.pointee.frames = frames
        slot.pointee.inputFlags = inputFlags
        slot.pointee.sourceFlags = sourceFlags
        slot.pointee.status = status
        slot.pointee.assetRange = range
        guard readablePCM, status == noErr, frames > 0, frames <= requested,
              requested <= maxFrames else { return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard list.count == (planar ? 2 : 1) else { fail(.invalidBuffers); return }
        for buffer in list {
            guard buffer.mNumberChannels == (planar ? 1 : 2), buffer.mData != nil,
                  Int(buffer.mDataByteSize) >= frames * Int(format.mBytesPerFrame) else {
                fail(.invalidBuffers); return
            }
        }
        slot.pointee.windowFrames = min(Self.windowFrames, frames)
        for window in 0..<3 {
            let firstFrame = slot.pointee.windowStart(window)
            for frame in 0..<slot.pointee.windowFrames {
                for channel in 0..<2 {
                    let buffer = list[planar ? channel : 0]
                    // Only reads the system's live storage, before callback return.
                    let source = buffer.mData!.assumingMemoryBound(to: Float.self)
                    let sourceIndex = planar ? firstFrame + frame : (firstFrame + frame) * 2 + channel
                    let destination = slot.pointee.sampleOffset + window * Self.samplesPerWindow + frame * 2 + channel
                    samples[destination] = source[sourceIndex]
                }
            }
        }
    }

    func finalize() {
        guard enter() else { return } // Never publish an overlapping writer.
        if prepared { fail(.unbalancedPreparation) }
        append(.finalize)
        leave()
        // Apple's finalize callback is the documented safe-to-free barrier.
        // A release/acquire pair publishes all records to the normal test actor.
        finalized.store(true, ordering: .releasing)
    }
}

private func task21TapInitialize(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                                 _ storage: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    guard let clientInfo else { return }
    let retained = Unmanaged<Task21HLSTapStorage>.fromOpaque(clientInfo).retain()
    storage.pointee = retained.toOpaque()
    let state = retained.takeUnretainedValue()
    if state.enter() { state.append(.initialize); state.leave() }
}

private func task21TapFinalize(_ tap: MTAudioProcessingTap) {
    let state = Unmanaged<Task21HLSTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeRetainedValue()
    state.finalize()
    withExtendedLifetime(state) {} // The callback's retain survives its final write.
}

private func task21TapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                              _ format: UnsafePointer<AudioStreamBasicDescription>) {
    Unmanaged<Task21HLSTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue().prepare(maxFrames: maxFrames, format: format.pointee)
}

private func task21TapUnprepare(_ tap: MTAudioProcessingTap) {
    Unmanaged<Task21HLSTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
}

private func task21TapProcess(_ tap: MTAudioProcessingTap, _ requested: CMItemCount,
                              _ flags: MTAudioProcessingTapFlags, _ buffers: UnsafeMutablePointer<AudioBufferList>,
                              _ framesOut: UnsafeMutablePointer<CMItemCount>,
                              _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let state = Unmanaged<Task21HLSTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let entered = state.enter()
    defer { if entered { state.leave() } }
    var range = CMTimeRange.invalid
    framesOut.pointee = 0
    flagsOut.pointee = 0
    // The ONLY source retrieval: pass the system's buffers/count/flags through
    // unchanged. Recording failure never trims, replaces, silences or crops audio.
    let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flagsOut, &range, framesOut)
    if entered {
        state.process(requested: requested, inputFlags: flags, frames: framesOut.pointee,
                      sourceFlags: flagsOut.pointee, status: status, range: range, buffers: buffers)
    }
}

/// A separate native-session reference experiment, not production session
/// authority and not an endpoint oracle. Run its sole selector in a fresh,
/// nonparallel simulator test process. The original graph session is synthetic.
/// This scope ends inactive and restores prior category settings; it does NOT
/// claim to discover/restore an unknown pre-existing activation state.
@MainActor
final class Task21NativeAudioSessionReference {
    enum Failure: Error { case requiresSimulator, alreadyOwned, activationRejected, deactivationRejected, restorationMismatch }
    private static var owned = false
    let diagnosticID = UUID()
    private let session: AVAudioSession
    private let priorCategory: AVAudioSession.Category
    private let priorMode: AVAudioSession.Mode
    private let priorPolicy: AVAudioSession.RouteSharingPolicy
    private let priorOptions: AVAudioSession.CategoryOptions
    private var configurationAttempted = false
    private var activationAttempted = false
    private var closed = false

    /// Register close() as an XCTest teardown block immediately after init, before
    /// calling activate(). Register fixture teardown later, so XCTest's LIFO order
    /// retires the player and finalizes its tap before deactivating the session.
    init() throws {
        #if !targetEnvironment(simulator)
        throw Failure.requiresSimulator
        #else
        guard !Self.owned else { throw Failure.alreadyOwned }
        session = AVAudioSession.sharedInstance()
        priorCategory = session.category
        priorMode = session.mode
        priorPolicy = session.routeSharingPolicy
        priorOptions = session.categoryOptions
        Self.owned = true
        Self.logRoute(stage: "reference-before-setup")
        #endif
    }

    func activate() async throws {
        configurationAttempted = true
        // One controlled setup change: explicitly establish a local playback
        // session. No output-device override, volume change or preferred-rate fix.
        try session.setCategory(.playback, mode: .moviePlayback, policy: .default, options: [])
        activationAttempted = true
        let activated = try await session.activate(options: [])
        print("AAC_NATIVE_SESSION activateReturned=\(activated)")
        guard activated else { throw Failure.activationRejected }
        Self.logRoute(stage: "reference-activation-return")
    }

    func close() async throws {
        guard !closed else { return }
        var cleanupError: (any Error)?
        if activationAttempted {
            do {
                let deactivated = try await session.deactivate(options: .notifyOthersOnDeactivation)
                print("AAC_NATIVE_SESSION deactivateReturned=\(deactivated)")
                guard deactivated else { throw Failure.deactivationRejected }
            } catch { cleanupError = error }
        }
        if configurationAttempted {
            do {
                try session.setCategory(priorCategory, mode: priorMode, policy: priorPolicy, options: priorOptions)
                guard session.category == priorCategory, session.mode == priorMode,
                      session.routeSharingPolicy == priorPolicy, session.categoryOptions == priorOptions else {
                    throw Failure.restorationMismatch
                }
            } catch {
                print("AAC_NATIVE_SESSION restoreFailed=\(error)")
                if cleanupError == nil { cleanupError = error }
            }
        }
        Self.logRoute(stage: "reference-cleanup-return")
        if let cleanupError {
            // Keep the reference reservation failed/owned: a later reference must
            // not silently proceed after unproven native-session cleanup.
            throw cleanupError
        }
        closed = true
        Self.owned = false
        print("AAC_NATIVE_SESSION cleanupSucceeded=true diagnosticID=\(diagnosticID.uuidString)")
    }

    static func logRoute(stage: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        // Port types and counts only, no route UIDs, device names or user media.
        let ports = outputs.prefix(4).map { "\($0.portType.rawValue):\($0.channels?.count ?? 0)" }.joined(separator: ",")
        print("AAC_NATIVE_ROUTE stage=\(stage) category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
            + "policy=\(session.routeSharingPolicy.rawValue) options=\(session.categoryOptions.rawValue) "
            + "outputCount=\(outputs.count) portTypesAndChannels=\(ports) outputChannels=\(session.outputNumberOfChannels) "
            + "sampleRate=\(session.sampleRate) ioDuration=\(session.ioBufferDuration) outputLatency=\(session.outputLatency) "
            + "outputVolume=\(session.outputVolume)")
    }
}

/// Separate simulator renderer/tap control. This uses a generated local PCM
/// asset and a documented track/mix association, not the HLS endpoint fixture.
/// Register close() before calling playThroughNaturalEnd(), after registering
/// the native-session owner's close(), so player/tap cleanup runs first.
@MainActor
final class Task21LocalPCMTapReference {
    enum Failure: Error { case format, asset, native(String), timeout(String), cleanup }
    enum Association: String { case assetTrack, wholeMix }
    private final class EndSignal: Sendable {
        let received = Atomic<Bool>(false)
    }
    private let directory: URL
    private let association: Association
    private let sessionDiagnosticID: UUID?
    private let player = AVPlayer()
    private let endSignal = EndSignal()
    private var item: AVPlayerItem?
    private var probe: Task21HLSAudioOutputProbe?
    private var endObserver: (any NSObjectProtocol)?
    private var closed = false

    init(association: Association = .assetTrack, sessionDiagnosticID: UUID? = nil) throws {
        self.association = association
        self.sessionDiagnosticID = sessionDiagnosticID
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task21-local-PCM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func playThroughNaturalEnd() async throws {
        let url = directory.appendingPathComponent("reference.caf")
        try Self.writePCM(to: url)
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        print("LOCAL_PCM_REFERENCE assetIsPlayable=\(playable)")
        guard playable else { throw Failure.asset }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        guard tracks.count == 1, CMTimeCompare(duration, CMTime(value: 2, timescale: 1)) == 0 else {
            throw Failure.asset
        }
        let physical = AVPlayerItem(asset: asset)
        item = physical
        player.replaceCurrentItem(with: physical)
        let scope = "LOCAL_PCM_REFERENCE association=\(association.rawValue)"
        switch association {
        case .assetTrack:
            probe = try Task21HLSAudioOutputProbe.attachLocalReference(
                to: physical, player: player, track: tracks[0], scope: scope)
        case .wholeMix:
            // mixID is documented for the mix of all audio tracks, with streaming
            // as a useful case rather than a restriction to streaming assets.
            probe = try Task21HLSAudioOutputProbe.attach(to: physical, player: player, scope: scope)
        }
        let signal = endSignal
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: physical, queue: nil) { _ in
                signal.received.store(true, ordering: .releasing)
            }
        print("LOCAL_PCM_REFERENCE assetFrames=96000 assetRate=48000 channels=2 "
            + "source=syntheticFloatPCM association=\(association.rawValue) registryPath=false endpointOracle=false")
        try await waitFor("ready") { player.status == .readyToPlay && physical.status == .readyToPlay }
        guard player.rate == 0, !player.disconnectedFromSystemAudio else { throw Failure.native("preroll-precondition") }
        // This is the same native preroll operation used by the HLS path. A
        // missing SDK completion remains subject to the outer XCTest timeout;
        // no timeout race fabricates return or abandons an outstanding callback.
        guard await player.preroll(atRate: 1) else { throw Failure.native("preroll") }
        probe?.mark(.prepared, player: player)
        probe?.mark(.activationRequested, player: player)
        player.play()
        try await waitFor("positive-rate") { player.rate > 0 }
        probe?.mark(.activationReturned, player: player)
        try await waitFor("natural-EOS") { signal.received.load(ordering: .acquiring) }
        probe?.mark(.naturalEnd, player: player)
        print("LOCAL_PCM_REFERENCE genuineItemEOS=true currentTimeIsOutputEvidence=false")
    }

    func close() async throws {
        guard !closed else { return }
        closed = true
        var failure: (any Error)?
        var noProcessingCandidate = false
        var referenceCleanupSucceeded = true
        probe?.mark(.retiring, player: player)
        player.pause()
        player.cancelPendingPrerolls()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        // Complete the actual physical disconnect before releasing the player
        // item. As with preroll, a lost native completion is an external timeout.
        await withCheckedContinuation { continuation in
            player.setDisconnectedFromSystemAudio(true) { continuation.resume() }
        }
        player.replaceCurrentItem(with: nil)
        item = nil
        if player.currentItem != nil || player.rate != 0 || !player.disconnectedFromSystemAudio {
            referenceCleanupSucceeded = false
            failure = Failure.cleanup
        }
        if let probe {
            do {
                let snapshot = try await probe.detachAndDrain()
                snapshot.log()
                // Exact completed absence signature only. Partial preparation,
                // any process callback, sticky fault or setup mismatch is not it.
                noProcessingCandidate = association == .wholeMix && probe.configurationStayedValid
                    && snapshot.firstFailure == 0 && snapshot.records.count == 2
                    && snapshot.records.first?.kind == .initialize
                    && snapshot.records.last?.kind == .finalize
                    && snapshot.records.allSatisfy({ $0.frames == 0 && $0.status == noErr })
                    && snapshot.markers.contains(where: { $0.phase == .prepared })
                    && snapshot.markers.contains(where: { $0.phase == .activationReturned && $0.rate > 0 })
                    && snapshot.markers.contains(where: { $0.phase == .naturalEnd })
                try snapshot.requireLocalPCMCallbackFeasibility()
                print("LOCAL_PCM_REFERENCE callbackFeasibility=true physicalTapFinalized=true endpointOracle=false")
            } catch {
                if failure == nil { failure = error }
                print("LOCAL_PCM_REFERENCE evidenceFailure=\(error)")
            }
        }
        probe = nil
        do { try FileManager.default.removeItem(at: directory) }
        catch {
            referenceCleanupSucceeded = false
            if failure == nil { failure = error }
        }
        print("LOCAL_PCM_REFERENCE cleanup itemAbsent=\(player.currentItem == nil) "
            + "rate=\(player.rate) disconnected=\(player.disconnectedFromSystemAudio) "
            + "temporaryDirectoryRemoved=\(!FileManager.default.fileExists(atPath: directory.path))")
        if let sessionDiagnosticID, noProcessingCandidate && referenceCleanupSucceeded
            && player.timeControlStatus == .paused {
            // Count only with the matching diagnosticID from this invocation's
            // later session-cleanup marker. Never pair markers across tests.
            print("AUDIO_CAPABILITY_OBSERVATION classification=wholeMixCallbacksNotObserved "
                + "diagnosticID=\(sessionDiagnosticID.uuidString) "
                + "capability=unverified observedUnavailableCount=1 endpointVerifiedCount=0 "
                + "referenceCleanupSucceeded=true sessionCleanup=requiresSeparateConfirmation")
        }
        // Preserve the existing strict failure; this marker never passes/skips it.
        if let failure { throw failure }
    }

    private func waitFor(_ stage: String, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !ready() {
            if player.status == .failed || item?.status == .failed {
                throw Failure.native("\(stage): player=\(String(describing: player.error)) item=\(String(describing: item?.error))")
            }
            guard player.currentItem === item else { throw Failure.native("item-replaced") }
            guard ContinuousClock.now < deadline else { throw Failure.timeout(stage) }
            try await Task.sleep(for: .milliseconds(10))
        }
        print("LOCAL_PCM_REFERENCE completedStage=\(stage) rate=\(player.rate)")
    }

    private static func writePCM(to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                        channels: 2, interleaved: true) else { throw Failure.format }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000),
              let channels = buffer.floatChannelData else { throw Failure.format }
        buffer.frameLength = 96_000
        for frame in 0..<Int(buffer.frameLength) {
            // Synthetic, quiet and deterministic stereo tones; no downloaded or
            // user media. Generation and allocations run only on the test actor.
            channels[0][frame] = Float(0.05 * sin(2 * Double.pi * Double(frame) / 480))
            channels[1][frame] = Float(0.05 * sin(2 * Double.pi * Double(frame) / 240))
        }
        try file.write(from: buffer)
        // The writer's synchronous scope ends before AVURLAsset opens its URL.
    }
}
