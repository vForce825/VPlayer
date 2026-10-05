// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Darwin
import ObjectiveC
import VPlayerCore

enum HLSNaturalEndPublicationResult: Sendable, Equatable {
    case endListPublished
    case insufficientInitialCoverage
}

/// 非 escaping、同步的泛型借用；实现者在自己的失败/关闭 fence 下执行准确一步。
protocol HLSNaturalEndPublicationScope: AnyObject, Sendable {
    func withActivePublication<T>(_ operation: () throws -> T) throws -> T
}

/// 同一 publisher 的 live/EOF 时钟与唯一 timer。store 域可调用这里只取本锁的方法；
/// Store 发信号只操作本锁；仅 timer 在退出本锁后调用 live graph，保持 graph→store 锁序。
final class HLSNaturalEndPublicationClock: @unchecked Sendable {
    struct CommitAnchor: Sendable {
        let logical: Int64
        let monotonic: UInt64
    }
    struct Instant {
        let logical: Int64
        let monotonic: UInt64
    }

    private static var fixedRuntimeAllowanceBytes: Int {
        let pointer = MemoryLayout<UnsafeRawPointer>.stride
        let timerHandler = malloc_good_size(16 + 3 * pointer) + 48
        let cancellationHandler = malloc_good_size(16 + pointer) + 48
        let graphScopeStorage = malloc_good_size(MemoryLayout<any HLSNaturalEndPublicationScope>.stride)
        return 128 + timerHandler + cancellationHandler + graphScopeStorage +
            64 + 32 + // 唯一 continuation 与 weak side table。
            3 * 512 + // 三层新增串行 async frame 的固定 ABI 余量；没有新增 Task runner。
            3 * malloc_good_size(pointer) + // graph、publisher、唯一 capacity slot 的引用存储。
            malloc_good_size(16 + pointer) + 48 + // live wake 的 weak graph capture。
            64 + 3 * 512 + malloc_good_size(pointer) // 唯一 producer wait 的有界 async frame 余量。
    }

    static var reservationBytes: Int {
        func object(_ type: AnyClass) -> Int { malloc_good_size(class_getInstanceSize(type)) }
        return object(HLSNaturalEndPublicationClock.self) + object(NSLock.self) +
            object(DispatchPlaybackMonotonicClock.self) +
            DispatchPlaybackMonotonicClock.deadlineTimerObjectAllocationBytes +
            object(PlaybackResourceContextReservation.self) +
            object(PlaybackApplicationChargeReservation.self) + fixedRuntimeAllowanceBytes
    }

    /// 对象以 malloc 实测；Dispatch source/capture/continuation/async frame 使用
    /// 固定 ABI 余量，不能把该部分声称为 native malloc 实测。
    var knownAllocationUpperBoundBytes: Int {
        func actual(_ object: AnyObject) -> Int {
            malloc_size(UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque()))
        }
        return actual(self) + actual(lock) + actual(clock) + actual(timer) + actual(reservation) +
            malloc_good_size(class_getInstanceSize(PlaybackApplicationChargeReservation.self)) +
            Self.fixedRuntimeAllowanceBytes
    }

    private let lock = NSLock()
    private let clock: any PlaybackMonotonicClock
    private let usesAbsoluteMonotonicTime: Bool
    private let ledger: PlaybackResourceContextLedger
    private let reservation: PlaybackResourceContextReservation
    private let timer: any PlaybackDeadlineTimer
    private var anchor: CommitAnchor?
    private var lastObserved: UInt64?
    private var clockWentBackwards = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var scheduledInstant: UInt64?
    private var pending = false
    private var cancelled = false
    private var stopped = false
    private var liveWakeHandler: (@Sendable () -> Void)?

    static func make(clock: (any PlaybackMonotonicClock)? = nil,
                     usesAbsoluteMonotonicTime: Bool = false,
                     ledger: PlaybackResourceContextLedger = .shared) throws
        -> HLSNaturalEndPublicationClock {
        let reservation = try ledger.reserve(allocationIdentity: .stable(UUID()),
            bytes: reservationBytes)
        let owner = HLSNaturalEndPublicationClock(
            clock: clock ?? DispatchPlaybackMonotonicClock(),
            usesAbsoluteMonotonicTime: usesAbsoluteMonotonicTime,
            ledger: ledger, reservation: reservation)
        try ledger.rebind(reservation, to: .object(ObjectIdentifier(owner)))
        return owner
    }

    private init(clock: any PlaybackMonotonicClock, usesAbsoluteMonotonicTime: Bool, ledger: PlaybackResourceContextLedger,
                 reservation: PlaybackResourceContextReservation) {
        self.clock = clock
        self.usesAbsoluteMonotonicTime = usesAbsoluteMonotonicTime
        self.ledger = ledger
        self.reservation = reservation
        timer = clock.makeDeadlineTimer(deliveryQueue: .global(qos: .userInitiated))
        timer.schedule(notAfterInstant: nil)
        // reservation 由真实 source handler 持有到其退出；cancel 不是物理释放证明。
        // handler 不强持 owner，所以 owner→timer→handler 没有强引用环。
        timer.setEventHandler { [weak self, reservation, ledger] in
            withExtendedLifetime((reservation, ledger)) { self?.timerFired() }
        }
        timer.activate()
    }

    deinit { timer.cancel() }

    /// 在同一 store CAS 内先验证时钟，commit 成功后才安装这个准确样本。
    func prepareCommit(logical: Int64) throws -> CommitAnchor {
        try lock.withLock { .init(logical: logical, monotonic: try readClockLocked()) }
    }

    func didCommit(_ value: CommitAnchor) {
        lock.withLock {
            // 可见 snapshot 已安装；下一 gate 从真实成功 CAS 完成处计时。
            // 若注入 clock 在 CAS 内倒退，保留已完成 transaction 的 bookkeeping，
            // 再由下一读取失败闭合，不能在已提交 mutation 中途抛出。
            let committedAt = clock.nowNanoseconds
            if committedAt < value.monotonic || lastObserved.map({ committedAt < $0 }) == true {
                clockWentBackwards = true
            }
            lastObserved = committedAt
            anchor = .init(logical: value.logical, monotonic: committedAt)
        }
        signal()
    }

    func now() throws -> Instant {
        try lock.withLock {
            let current = try readClockLocked()
            if usesAbsoluteMonotonicTime {
                guard let value = Int64(exactly: current) else {
                    throw HLSPublicationFailure.arithmeticOverflow
                }
                return .init(logical: value, monotonic: current)
            }
            guard let anchor else { return .init(logical: 0, monotonic: current) }
            guard current >= anchor.monotonic,
                  let elapsed = Int64(exactly: current - anchor.monotonic) else {
                throw HLSPublicationFailure.arithmeticOverflow
            }
            return .init(logical: try HLSChecked.add(anchor.logical, elapsed), monotonic: current)
        }
    }

    func monotonicDeadline(for logical: Int64, from now: Instant) throws -> UInt64 {
        guard logical >= now.logical else { throw HLSPublicationFailure.arithmeticOverflow }
        let remaining = logical.subtractingReportingOverflow(now.logical)
        guard !remaining.overflow, let duration = UInt64(exactly: remaining.partialValue) else {
            throw HLSPublicationFailure.arithmeticOverflow
        }
        let result = now.monotonic.addingReportingOverflow(duration)
        guard !result.overflow else { throw HLSPublicationFailure.arithmeticOverflow }
        return result.partialValue
    }

    private func readClockLocked() throws -> UInt64 {
        guard !stopped else { throw HLSPublicationFailure.closed }
        let value = clock.nowNanoseconds
        guard !clockWentBackwards, lastObserved.map({ value >= $0 }) ?? true else {
            throw HLSPublicationFailure.arithmeticOverflow
        }
        lastObserved = value
        return value
    }

    /// HTTP response tails may outlive the publication timer. Residency still
    /// samples this same monotonic domain after publication admission is closed.
    var residencyNowNanoseconds: Int64 { Int64(clamping: clock.nowNanoseconds) }

    var hasLiveWakeHandler: Bool { lock.withLock { liveWakeHandler != nil && !stopped } }

    func installLiveWakeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            precondition(liveWakeHandler == nil && continuation == nil && !stopped)
            liveWakeHandler = handler
        }
    }

    func scheduleLiveWake(until instant: UInt64?) {
        lock.withLock {
            guard !stopped, liveWakeHandler != nil, continuation == nil else { return }
            // A capacity signal between state inspection and rearm must win.
            // It is consumed by the next graph turn, never lost to a later gate.
            let deadline = pending ? min(instant ?? UInt64.max, clock.nowNanoseconds) : instant
            scheduledInstant = deadline
            timer.schedule(notAfterInstant: deadline)
        }
    }

    func removeLiveWakeHandler() {
        lock.withLock {
            liveWakeHandler = nil
            if continuation == nil {
                scheduledInstant = nil
                timer.schedule(notAfterInstant: nil)
            }
        }
    }

    /// 每次读取 publisher 前消费合并信号；读取后到 install wait 之间的通知不能丢失。
    func consumeSignal() { lock.withLock { pending = false } }

    func signal() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !stopped else { return nil }
            pending = true
            if let waiter = continuation {
                continuation = nil
                scheduledInstant = nil
                timer.schedule(notAfterInstant: nil)
                return waiter
            }
            if liveWakeHandler != nil {
                // Store callbacks cannot enter graph while holding the store lock.
                // The same timer coalesces signals and re-enters graph asynchronously.
                let now = clock.nowNanoseconds
                scheduledInstant = now
                timer.schedule(notAfterInstant: now)
            }
            return nil
        }
        waiter?.resume()
    }

    private func timerFired() {
        let delivery = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            guard !stopped, let scheduledInstant else { return (false, nil) }
            let now = clock.nowNanoseconds
            guard now >= scheduledInstant || lastObserved.map({ now < $0 }) == true else {
                // An early or stale physical delivery cannot cancel a later schedule.
                timer.schedule(notAfterInstant: scheduledInstant)
                return (false, nil)
            }
            if let liveWakeHandler {
                self.scheduledInstant = nil
                timer.schedule(notAfterInstant: nil)
                return (true, liveWakeHandler)
            }
            return (true, nil)
        }
        guard delivery.0 else { return }
        if let liveWakeHandler = delivery.1 { liveWakeHandler() }
        else { signal() }
    }

    func wait(until instant: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                let immediate = lock.withLock { () -> Result<Void, Error>? in
                    guard !cancelled, !Task.isCancelled else { return .failure(CancellationError()) }
                    guard !stopped else { return .failure(HLSPublicationFailure.closed) }
                    guard liveWakeHandler == nil else { return .failure(HLSPublicationFailure.identityMismatch) }
                    guard continuation == nil else { return .failure(HLSPublicationFailure.capacityExceeded) }
                    if pending { pending = false; return .success(()) }
                    continuation = waiter
                    scheduledInstant = instant
                    timer.schedule(notAfterInstant: instant)
                    return nil
                }
                if let immediate { waiter.resume(with: immediate) }
            }
        } onCancel: { [self] in cancel() }
    }

    private func cancel() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            cancelled = true
            defer { continuation = nil; scheduledInstant = nil }
            timer.schedule(notAfterInstant: nil)
            return continuation
        }
        waiter?.resume(throwing: CancellationError())
    }

    func stopWaiting() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            stopped = true
            liveWakeHandler = nil
            defer { continuation = nil; scheduledInstant = nil }
            timer.schedule(notAfterInstant: nil)
            return continuation
        }
        timer.cancel()
        waiter?.resume(throwing: HLSPublicationFailure.closed)
    }
}

/// 同一 item 的 writer→validator→publisher→store 汇合点。所有 readiness 都来自
/// `HLSPublicationCoordinator.visible`，不会用 packet 数或布尔标志伪造三秒前缀。
final class SystemHLSPublicationGraph: HLSNaturalEndPublicationScope, @unchecked Sendable {
    final class RelayHolder: @unchecked Sendable { weak var relay: SegmentReportRelay? }

    private final class Window {
        let binding: FMP4WriterBinding
        let mediaType: FinalFMP4MediaType
        let relay: SegmentReportRelay
        let writer: SegmentedFMP4Writer
        var initialization: SealedMediaObject?
        var proof: EpochFormatProof?
        var timeline: SegmentTimelineValidator?
        var pendingMedia: [SealedMediaObject] = []
        var installed = false

        init(binding: FMP4WriterBinding, mediaType: FinalFMP4MediaType,
             relay: SegmentReportRelay, writer: SegmentedFMP4Writer) {
            self.binding = binding
            self.mediaType = mediaType
            self.relay = relay
            self.writer = writer
        }
    }

    private let condition = NSCondition()
    let token: LoopbackSessionToken
    private let itemGeneration: UInt64
    private let publicationDeadlineNanoseconds: Int64
    private let initialWindowMinimumSeconds: UInt8
    private let publicationClock: HLSNaturalEndPublicationClock
    private var windows: [UInt64: Window] = [:]
    private var initialWriterIDs: [UInt64] = []
    private var currentByParticipant: [UInt64: Window] = [:]
    private var storedError: ErrorDiagnosticSnapshot?
    private var failureSink: (@Sendable (ErrorDiagnosticSnapshot) -> Void)?
    private var naturalEndPending = false
    // Removing a timer handler cannot revoke a closure already selected for
    // delivery. This graph-lock fence remains revoked after EOF completes.
    private var livePublicationActive = true
    private var closed = false
    private var producerWaitCancelled = false
    private var producerWaiter: CheckedContinuation<Void, Error>?
    private var prefixUnavailableAtNaturalEnd = false
    private var lastLogicalSequence: UInt64 = 0
    private var videoFrameRateMilli: UInt64?
    private var expectsVideo = true
    private var audioCandidate: HLSAudioCandidateRegistration?
    private(set) var store: SealedMediaStore?
    private(set) var declaration: HLSItemDeclaration?
    private(set) var publisher: HLSPublicationCoordinator?
    #if DEBUG
    // 测试只控制真实 callback 的到达顺序，不替代 validator、offer 或来源凭据。
    private var beforeReceiveForTesting: (@Sendable (SealedMediaObject) -> Void)?
    private var beforeLiveWakeForTesting: (@Sendable () -> Void)?
    private var afterLiveWakeForTesting: (@Sendable () -> Void)?

    /// Observes an already-selected live delivery outside the graph lock; tests
    /// can hold the real timer callback across EOF/retirement without forging it.
    func installLiveWakeObserverForTesting(
        before: @escaping @Sendable () -> Void,
        after: @escaping @Sendable () -> Void
    ) {
        condition.withLock {
            beforeLiveWakeForTesting = before
            afterLiveWakeForTesting = after
        }
    }

    func installBeforeReceiveForTesting(
        _ observer: @escaping @Sendable (SealedMediaObject) -> Void
    ) {
        condition.withLock { beforeReceiveForTesting = observer }
    }
    #endif

    init(itemGeneration: UInt64,
         publicationDeadlineNanoseconds: Int64 = 120_000_000_000,
         initialWindowMinimumSeconds: Int = 6,
         clock: (any PlaybackMonotonicClock)? = nil) throws {
        guard publicationDeadlineNanoseconds > 0,
              [3, 4, 6].contains(initialWindowMinimumSeconds) else {
            throw HLSPublicationFailure.invalidDuration
        }
        self.itemGeneration = itemGeneration
        self.initialWindowMinimumSeconds = UInt8(initialWindowMinimumSeconds)
        self.publicationDeadlineNanoseconds = publicationDeadlineNanoseconds
        publicationClock = try HLSNaturalEndPublicationClock.make(
            clock: clock, usesAbsoluteMonotonicTime: true)
        token = try LoopbackSessionToken.generateSystemCapability()
        publicationClock.installLiveWakeHandler { [weak self] in self?.livePublicationWake() }
    }

    func installFailureSink(_ sink: @escaping @Sendable (ErrorDiagnosticSnapshot) -> Void) {
        condition.withLock {
            precondition(failureSink == nil && storedError == nil)
            failureSink = sink
        }
    }

    /// Selected demux topology is frozen before creating any writer or publication.
    /// Single-audio uses the same validated media/store path and a genuine candidate
    /// registration; a caller-provided ready flag cannot publish a radio item.
    func configureAudioOnly() throws {
        try condition.withLock {
            guard publisher == nil, windows.isEmpty, videoFrameRateMilli == nil else {
                throw HLSPublicationFailure.identityMismatch
            }
            expectsVideo = false
        }
    }

    func configureVideo(frameRate: MediaRational?) throws {
        guard let frameRate, frameRate.num > 0, frameRate.den > 0 else {
            throw HLSPublicationFailure.invalidPlaylist
        }
        let scaled = Int64(frameRate.num).multipliedReportingOverflow(by: 1_000)
        guard !scaled.overflow else { throw HLSPublicationFailure.invalidPlaylist }
        let value = scaled.partialValue / Int64(frameRate.den)
        guard let milli = UInt64(exactly: value), milli > 0, milli <= 60_000 else {
            throw HLSPublicationFailure.invalidPlaylist
        }
        try condition.withLock {
            guard expectsVideo, publisher == nil,
                  videoFrameRateMilli == nil || videoFrameRateMilli == milli else {
                throw HLSPublicationFailure.identityMismatch
            }
            videoFrameRateMilli = milli
        }
    }

    func makeRelay(binding: FMP4WriterBinding, mediaType: FinalFMP4MediaType,
                   limits: FMP4WriterLimits, initial: Bool = true,
                   writerFactory: (SegmentReportRelay) throws -> SegmentedFMP4Writer)
        throws -> SegmentedFMP4Writer {
        let holder = RelayHolder()
        let relay = SegmentReportRelay(binding: binding, limits: limits, capacity: 8) {
            [weak self, holder] object in
            guard let relay = holder.relay else { return }
            self?.receive(object, relay: relay)
        }
        holder.relay = relay
        let writer = try writerFactory(relay)
        condition.withLock {
            precondition(windows[binding.writerIdentity.rawValue] == nil)
            windows[binding.writerIdentity.rawValue] = Window(
                binding: binding, mediaType: mediaType, relay: relay, writer: writer)
            if initial { initialWriterIDs.append(binding.writerIdentity.rawValue) }
        }
        return writer
    }

    private func receive(_ object: SealedMediaObject, relay: SegmentReportRelay) {
        #if DEBUG
        let observer = condition.withLock { beforeReceiveForTesting }
        observer?(object)
        #endif
        var firstFailure: (ErrorDiagnosticSnapshot, @Sendable (ErrorDiagnosticSnapshot) -> Void)?
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
            // authority.fail 会反向 recordFailure；必须先退出本图的 condition。
            if let (diagnostic, sink) = firstFailure { sink(diagnostic) }
        }
        guard !closed, storedError == nil,
              let window = windows[object.binding.writerIdentity.rawValue],
              window.relay === relay else {
            _ = relay.releaseForControl(object)
            return
        }
        do {
            switch object.kind {
            case .initialization:
                guard window.initialization == nil else {
                    throw HLSPublicationFailure.identityMismatch
                }
                window.initialization = object
                window.proof = try FinalFMP4Validator(
                    binding: window.binding, mediaType: window.mediaType)
                    .validateInitialization(object)
                if publisher == nil { try installInitialIfReadyLocked() }
                else if !window.installed { try installSuccessorLocked(window) }
            case .media:
                if publisher == nil {
                    guard window.pendingMedia.count < 16 else {
                        PlaybackDiagnosticTracker.shared.set("pub_err_pend_med_\(window.mediaType)_\(window.pendingMedia.count)")
                        throw HLSPublicationFailure.capacityExceeded
                    }
                    window.pendingMedia.append(object)
                    return
                }
                try offerLocked(object, window: window)
            }
        } catch {
            PlaybackDiagnosticTracker.shared.set("pub_err_s\(object.logicalSequence)_\(window.mediaType)_\(error)")
            if storedError == nil {
                let diagnostic = PlaybackErrorDiagnostics.snapshot(error)
                storedError = diagnostic
                publicationClock.removeLiveWakeHandler()
                if let publisher { publisher.cancelCapacityWait(ticket: publisher.ticket) }
                resumeProducerLocked(throwing: diagnostic)
                if let failureSink { firstFailure = (diagnostic, failureSink) }
            }
            _ = relay.releaseForControl(object)
        }
    }

    private func installInitialIfReadyLocked() throws {
        guard publisher == nil, initialWriterIDs.count == (expectsVideo ? 2 : 1) else { return }
        let initial = initialWriterIDs.compactMap { windows[$0] }
        guard initial.count == initialWriterIDs.count,
              initial.allSatisfy({ $0.initialization != nil && $0.proof != nil }),
              let audio = initial.first(where: { $0.mediaType == .audio }),
              let audioFormat = audio.initialization?.publicationEvidence?.format else { return }
        let videoDeclaration: HLSVideoDeclaration?
        if expectsVideo {
            guard let video = initial.first(where: { $0.mediaType == .video }),
                  let videoFrameRateMilli,
                  let videoFormat = video.initialization?.publicationEvidence?.format else { return }
            videoDeclaration = .init(
                participantID: video.binding.publicationParticipantID.rawValue,
                codec: videoFormat.codec, width: videoFormat.width,
                height: videoFormat.height, frameRateMilli: videoFrameRateMilli,
                videoRange: videoFormat.videoRange, peakEnvelope: 160_000_000)
        } else {
            videoDeclaration = nil
        }
        let declaration = HLSItemDeclaration(
            itemGeneration: itemGeneration,
            token: token.value,
            video: videoDeclaration,
            audio: [.init(
                participantID: audio.binding.publicationParticipantID.rawValue,
                renditionID: "main-aac", codec: .aac,
                channels: audioFormat.channels, language: nil,
                score: 100, peakEnvelope: 2_048_000)])
        let store = SealedMediaStore(loopbackSession: token, itemGeneration: itemGeneration,
                                    publicationClock: publicationClock)
        let candidate: HLSAudioCandidateRegistration?
        if !expectsVideo, let initialization = audio.initialization, let proof = audio.proof {
            candidate = try store.registerAudioCandidate(
                initialization: initialization, proof: proof, declaration: declaration)
        } else {
            candidate = nil
        }
        let participants = try initial.map { window -> HLSInitialParticipant in
            guard let initialization = window.initialization, let proof = window.proof else {
                throw HLSPublicationFailure.identityMismatch
            }
            return HLSInitialParticipant(
                initialization: initialization, proof: proof, relay: window.relay,
                candidateTicket: candidate?.ticket, candidate: candidate,
                aacTerminalBinding: window.mediaType == .audio
                    ? window.writer.aacTerminalBinding : nil,
                aacRenditionBinding: window.mediaType == .audio
                    ? window.writer.aacRenditionTerminalBinding : nil)
        }
        let publisher = try HLSPublicationCoordinator(
            store: store, participants: participants, declaration: declaration,
            anchor: .init(mediaOrigin: .init(value: 0, timescale: 1),
                          utcMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)),
            publicationDeadlineNanoseconds: publicationDeadlineNanoseconds,
            initialWindowMinimumSeconds: Int(initialWindowMinimumSeconds), publicationClock: publicationClock)
        for window in initial {
            window.installed = true
            currentByParticipant[window.binding.publicationParticipantID.rawValue] = window
        }
        self.store = store
        self.audioCandidate = candidate
        self.declaration = declaration
        self.publisher = publisher
        for window in initial {
            let pending = window.pendingMedia
            window.pendingMedia.removeAll(keepingCapacity: true)
            for object in pending { try offerLocked(object, window: window) }
        }
    }

    private func installSuccessorLocked(_ window: Window) throws {
        let participantID = window.binding.publicationParticipantID.rawValue
        guard let publisher,
              let previous = currentByParticipant[participantID],
              previous.initialization != nil,
              previous.proof != nil,
              let successorInitialization = window.initialization,
              let successorProof = window.proof else {
            throw HLSPublicationFailure.identityMismatch
        }
        if window.mediaType == .audio {
            guard let terminal = window.writer.aacTerminalBinding,
                  let rendition = window.writer.aacRenditionTerminalBinding,
                  let admission = window.writer.aacWriterWindowAdmission else {
                throw HLSPublicationFailure.identityMismatch
            }
            _ = try publisher.advanceAACWriterWindow(
                .init(initialization: successorInitialization, proof: successorProof,
                      relay: window.relay, candidateTicket: audioCandidate?.ticket,
                      candidate: audioCandidate,
                      aacTerminalBinding: terminal,
                      aacRenditionBinding: rendition,
                      aacWriterWindowAdmission: admission),
                admission: admission, ticket: publisher.ticket)
        } else {
            guard let admission = window.writer.writerWindowAdmission else {
                throw HLSPublicationFailure.identityMismatch
            }
            _ = try publisher.advanceWriterWindow(
                .init(initialization: successorInitialization, proof: successorProof,
                      relay: window.relay, candidateTicket: nil,
                      writerWindowAdmission: admission),
                admission: admission, ticket: publisher.ticket)
        }
        window.installed = true
        currentByParticipant[participantID] = window
    }

    private func offerLocked(_ object: SealedMediaObject, window: Window) throws {
        guard let publisher, let proof = window.proof, window.installed else {
            throw HLSPublicationFailure.identityMismatch
        }
        let timeline = window.timeline ?? SegmentTimelineValidator(
            proof: proof, firstLogicalSequence: object.logicalSequence)
        window.timeline = timeline
        let receipt = try timeline.validate(object, using: proof)
        lastLogicalSequence = max(lastLogicalSequence, object.logicalSequence)
        _ = try publisher.offer(
            object, receipt: receipt, relay: window.relay, ticket: publisher.ticket,
            now: publicationClock.now().logical, naturalEndTail: naturalEndPending)
        if !naturalEndPending { try advanceLivePublicationLocked() }
    }

    /// One timer owns ordinary gates, capacity notifications and the unchanged
    /// ticket deadline. Every wake revalidates under graph → store lock ordering.
    private func advanceLivePublicationLocked() throws {
        guard !closed, livePublicationActive, !naturalEndPending, let publisher else { return }
        if let storedError { throw storedError }
        publicationClock.consumeSignal()
        let instant = try publicationClock.now()
        _ = try publisher.publish(ticket: publisher.ticket, now: instant.logical)
        let wake = try publisher.nextLivePublicationWake(now: instant.logical)
        publicationClock.scheduleLiveWake(until: try wake.map {
            try publicationClock.monotonicDeadline(for: $0, from: instant)
        })
        if !publisher.shouldBackpressureProducer { resumeProducerLocked() }
        condition.broadcast()
    }

    private func livePublicationWake() {
        #if DEBUG
        let observer = condition.withLock { (beforeLiveWakeForTesting, afterLiveWakeForTesting) }
        observer.0?()
        defer { observer.1?() }
        #endif
        var failure: (ErrorDiagnosticSnapshot, @Sendable (ErrorDiagnosticSnapshot) -> Void)?
        condition.withLock {
            guard !closed, livePublicationActive, !naturalEndPending, storedError == nil else { return }
            do { try advanceLivePublicationLocked() }
            catch {
                let diagnostic = PlaybackErrorDiagnostics.snapshot(error)
                storedError = diagnostic
                publicationClock.removeLiveWakeHandler()
                if let publisher { publisher.cancelCapacityWait(ticket: publisher.ticket) }
                resumeProducerLocked(throwing: diagnostic)
                condition.broadcast()
                if let failureSink { failure = (diagnostic, failureSink) }
            }
        }
        if let (diagnostic, sink) = failure { sink(diagnostic) }
    }

    /// The sole media worker suspends only when a complete common prefix can
    /// drain independently. A leading track alone must not prevent its partner
    /// from reaching the matching boundary. No callback owns a blocking wait.
    func waitForProducerCapacity() async throws {
        try Task.checkCancellation()
        let needsWait = try condition.withLock {
            if let storedError { throw storedError }
            guard !closed else { throw HLSPublicationFailure.closed }
            return !naturalEndPending && publisher?.shouldBackpressureProducer == true
        }
        guard needsWait else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                let immediate = condition.withLock { () -> Result<Void, Error>? in
                    if Task.isCancelled || producerWaitCancelled { return .failure(CancellationError()) }
                    if let storedError { return .failure(storedError) }
                    guard !closed else { return .failure(HLSPublicationFailure.closed) }
                    guard !naturalEndPending, publisher?.shouldBackpressureProducer == true else {
                        return .success(())
                    }
                    guard producerWaiter == nil else { return .failure(HLSPublicationFailure.capacityExceeded) }
                    producerWaiter = waiter
                    return nil
                }
                if let immediate { waiter.resume(with: immediate) }
            }
        } onCancel: { [self] in
            condition.withLock {
                producerWaitCancelled = true
                resumeProducerLocked(throwing: CancellationError())
            }
        }
    }

    private func resumeProducerLocked(throwing error: (any Error)? = nil) {
        guard let waiter = producerWaiter else { return }
        producerWaiter = nil
        if let error { waiter.resume(throwing: error) }
        else { waiter.resume() }
    }

    /// Retirement closes publication admission before joining the media worker.
    /// The store itself remains alive until writer and HTTP tails have drained.
    func cancelLivePublication() {
        condition.withLock {
            closed = true
            livePublicationActive = false
            publicationClock.stopWaiting()
            if let publisher { publisher.cancelCapacityWait(ticket: publisher.ticket) }
            resumeProducerLocked(throwing: CancellationError())
            condition.broadcast()
        }
    }

    /// demux 已交付真实 EOF 后，writer drain 仍可能同步产生带 AAC padding 的最后片段。
    /// 这些片段先进入 publisher records，等所有 writer terminal authority 齐备后再做
    /// 有界 natural-end drain；不能把尾片当普通中段提前发布。
    func beginNaturalEnd() {
        condition.withLock {
            naturalEndPending = true
            livePublicationActive = false
            publicationClock.removeLiveWakeHandler()
            if let publisher { publisher.cancelCapacityWait(ticket: publisher.ticket) }
            resumeProducerLocked()
        }
    }

    func waitForVisible(until deadline: Date) throws
        -> (SealedMediaStore, HLSItemDeclaration, HLSPublishedSnapshot)? {
        condition.lock()
        defer { condition.unlock() }
        while !closed && publisher?.visible == nil && storedError == nil
                && !prefixUnavailableAtNaturalEnd {
            guard condition.wait(until: deadline) else { return nil }
        }
        if let storedError { throw storedError }
        guard !closed else { throw HLSPublicationFailure.closed }
        guard let store, let declaration, let snapshot = publisher?.visible else { return nil }
        return (store, declaration, snapshot)
    }

    func finishNaturalEnd() async throws -> HLSNaturalEndPublicationResult {
        let publisher = try condition.withLock {
            if let storedError { throw storedError }
            guard naturalEndPending, let publisher else { throw HLSPublicationFailure.identityMismatch }
            return publisher
        }
        let result = try await publisher.drainNaturalEnd(scope: self)
        try condition.withLock {
            if let storedError { throw storedError }
            if result == .insufficientInitialCoverage { prefixUnavailableAtNaturalEnd = true }
            naturalEndPending = false
            condition.broadcast()
        }
        return result
    }

    func withActivePublication<T>(_ operation: () throws -> T) throws -> T {
        try condition.withLock {
            if let storedError { throw storedError }
            guard !closed else { throw HLSPublicationFailure.closed }
            return try operation()
        }
    }

    func recordFailure(_ error: Error) {
        condition.withLock {
            if storedError == nil { storedError = PlaybackErrorDiagnostics.snapshot(error) }
            publicationClock.removeLiveWakeHandler()
            if let publisher { publisher.cancelCapacityWait(ticket: publisher.ticket) }
            resumeProducerLocked(throwing: storedError)
            condition.broadcast()
        }
        publicationClock.signal()
    }

    func close() {
        cancelLivePublication()
        condition.withLock {
            publisher?.close()
            for window in windows.values { window.relay.closePublications() }
            store?.close()
            condition.broadcast()
        }
    }
}
