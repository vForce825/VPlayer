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

    private let scope: String
    private let physicalItemIdentity: ObjectIdentifier
    private let state: Task21HLSTapStorage
    private var item: AVPlayerItem?
    /// AVPlayerItem copies the assigned mix. Track the installed copy weakly so
    /// ownership verification cannot itself retain the tap through finalization.
    private weak var installedMix: AVAudioMix?
    private var tap: MTAudioProcessingTap?
    private var rateObservation: NSKeyValueObservation?
    private var markers: [Marker] = []
    private var drained: Snapshot?

    private init(item: AVPlayerItem, scope: String, state: Task21HLSTapStorage, tap: MTAudioProcessingTap) {
        self.item = item
        self.scope = scope
        physicalItemIdentity = ObjectIdentifier(item)
        self.state = state
        self.tap = tap
        markers.reserveCapacity(16)
    }

    static func attach(to item: AVPlayerItem, player: AVPlayer, scope: String) throws -> Task21HLSAudioOutputProbe {
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
        let probe = Task21HLSAudioOutputProbe(item: item, scope: scope, state: state, tap: tap)
        probe.rateObservation = player.observe(\.rate, options: [.initial, .new]) { _, change in
            if let rate = change.newValue { state.observedRate.store(rate.bitPattern, ordering: .releasing) }
        }
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = AVAudioMixInputParametersTrackID.mixID.rawValue
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
