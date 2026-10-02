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

/// 一个 publisher 的 commit 时钟与 EOF 等待槽。store 域可调用这里只取本锁的方法；
/// 本类型从不反向调用 publisher、store 或 graph，因此不会倒置 graph→store 的锁序。
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
            3 * malloc_good_size(pointer) // graph、publisher、唯一 capacity slot 的引用存储。
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

    static func make(clock: (any PlaybackMonotonicClock)? = nil,
                     ledger: PlaybackResourceContextLedger = .shared) throws
        -> HLSNaturalEndPublicationClock {
        let reservation = try ledger.reserve(allocationIdentity: .stable(UUID()),
            bytes: reservationBytes)
        let owner = HLSNaturalEndPublicationClock(
            clock: clock ?? DispatchPlaybackMonotonicClock(),
            ledger: ledger, reservation: reservation)
        try ledger.rebind(reservation, to: .object(ObjectIdentifier(owner)))
        return owner
    }

    private init(clock: any PlaybackMonotonicClock, ledger: PlaybackResourceContextLedger,
                 reservation: PlaybackResourceContextReservation) {
        self.clock = clock
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

    /// 每次读取 publisher 前消费合并信号；读取后到 install wait 之间的通知不能丢失。
    func consumeSignal() { lock.withLock { pending = false } }

    func signal() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !stopped else { return nil }
            pending = true
            guard let waiter = continuation else { return nil }
            continuation = nil
            scheduledInstant = nil
            timer.schedule(notAfterInstant: nil)
            return waiter
        }
        waiter?.resume()
    }

    private func timerFired() {
        let due = lock.withLock { () -> Bool in
            guard let scheduledInstant else { return false }
            let now = clock.nowNanoseconds
            if now >= scheduledInstant || lastObserved.map({ now < $0 }) == true { return true }
            // 迟到旧回调或测试 early-fire 不能撤销仍有效的新排期。
            timer.schedule(notAfterInstant: scheduledInstant)
            return false
        }
        if due { signal() }
    }

    func wait(until instant: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                let immediate = lock.withLock { () -> Result<Void, Error>? in
                    guard !cancelled, !Task.isCancelled else { return .failure(CancellationError()) }
                    guard !stopped else { return .failure(HLSPublicationFailure.closed) }
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
    private let publicationClock: HLSNaturalEndPublicationClock
    private var windows: [UInt64: Window] = [:]
    private var initialWriterIDs: [UInt64] = []
    private var currentByParticipant: [UInt64: Window] = [:]
    private var storedError: ErrorDiagnosticSnapshot?
    private var failureSink: (@Sendable (ErrorDiagnosticSnapshot) -> Void)?
    private var naturalEndPending = false
    private var prefixUnavailableAtNaturalEnd = false
    private var lastLogicalSequence: UInt64 = 0
    private var videoFrameRateMilli: UInt64?
    private(set) var store: SealedMediaStore?
    private(set) var declaration: HLSItemDeclaration?
    private(set) var publisher: HLSPublicationCoordinator?
    #if DEBUG
    // 测试只控制真实 callback 的到达顺序，不替代 validator、offer 或来源凭据。
    private var beforeReceiveForTesting: (@Sendable (SealedMediaObject) -> Void)?

    func installBeforeReceiveForTesting(
        _ observer: @escaping @Sendable (SealedMediaObject) -> Void
    ) {
        condition.withLock { beforeReceiveForTesting = observer }
    }
    #endif

    init(itemGeneration: UInt64,
         publicationDeadlineNanoseconds: Int64 = 120_000_000_000) throws {
        guard publicationDeadlineNanoseconds > 0 else {
            throw HLSPublicationFailure.invalidDuration
        }
        self.itemGeneration = itemGeneration
        self.publicationDeadlineNanoseconds = publicationDeadlineNanoseconds
        publicationClock = try HLSNaturalEndPublicationClock.make()
        token = try LoopbackSessionToken.generateSystemCapability()
    }

    func installFailureSink(_ sink: @escaping @Sendable (ErrorDiagnosticSnapshot) -> Void) {
        condition.withLock {
            precondition(failureSink == nil && storedError == nil)
            failureSink = sink
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
            guard publisher == nil,
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
        guard storedError == nil,
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
                if let failureSink { firstFailure = (diagnostic, failureSink) }
            }
            _ = relay.releaseForControl(object)
        }
    }

    private func installInitialIfReadyLocked() throws {
        guard publisher == nil, initialWriterIDs.count >= 2 else { return }
        let initial = initialWriterIDs.compactMap { windows[$0] }
        guard initial.count == initialWriterIDs.count,
              initial.allSatisfy({ $0.initialization != nil && $0.proof != nil }),
              let video = initial.first(where: { $0.mediaType == .video }),
              let audio = initial.first(where: { $0.mediaType == .audio }),
              let videoFrameRateMilli,
              let videoFormat = video.initialization?.publicationEvidence?.format,
              let audioFormat = audio.initialization?.publicationEvidence?.format else { return }
        let declaration = HLSItemDeclaration(
            itemGeneration: itemGeneration,
            token: token.value,
            video: .init(
                participantID: video.binding.publicationParticipantID.rawValue,
                codec: videoFormat.codec, width: videoFormat.width,
                height: videoFormat.height, frameRateMilli: videoFrameRateMilli,
                videoRange: videoFormat.videoRange, peakEnvelope: 160_000_000),
            audio: [.init(
                participantID: audio.binding.publicationParticipantID.rawValue,
                renditionID: "main-aac", codec: .aac,
                channels: audioFormat.channels, language: nil,
                score: 100, peakEnvelope: 2_048_000)])
        let store = SealedMediaStore(loopbackSession: token, itemGeneration: itemGeneration)
        let participants = try initial.map { window -> HLSInitialParticipant in
            guard let initialization = window.initialization, let proof = window.proof else {
                throw HLSPublicationFailure.identityMismatch
            }
            return HLSInitialParticipant(
                initialization: initialization, proof: proof, relay: window.relay,
                candidateTicket: nil,
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
            initialWindowMinimumSeconds: 3, publicationClock: publicationClock)
        for window in initial {
            window.installed = true
            currentByParticipant[window.binding.publicationParticipantID.rawValue] = window
        }
        self.store = store
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
                      relay: window.relay, candidateTicket: nil,
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
        let result = try publisher.offer(
            object, receipt: receipt, relay: window.relay, ticket: publisher.ticket,
            now: Int64(object.logicalSequence + 1) * 1_000_000_000,
            naturalEndTail: naturalEndPending)
        if case .accepted = result {
            if naturalEndPending { return }
            _ = try publisher.publish(
                ticket: publisher.ticket,
                now: Int64(object.logicalSequence + 1) * 1_000_000_000)
        }
    }

    /// demux 已交付真实 EOF 后，writer drain 仍可能同步产生带 AAC padding 的最后片段。
    /// 这些片段先进入 publisher records，等所有 writer terminal authority 齐备后再做
    /// 有界 natural-end drain；不能把尾片当普通中段提前发布。
    func beginNaturalEnd() {
        condition.withLock { naturalEndPending = true }
    }

    func waitForVisible(until deadline: Date) throws
        -> (SealedMediaStore, HLSItemDeclaration, HLSPublishedSnapshot)? {
        condition.lock()
        defer { condition.unlock() }
        while publisher?.visible == nil && storedError == nil
                && !prefixUnavailableAtNaturalEnd {
            guard condition.wait(until: deadline) else { return nil }
        }
        if let storedError { throw storedError }
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
            return try operation()
        }
    }

    func recordFailure(_ error: Error) {
        condition.withLock {
            if storedError == nil { storedError = PlaybackErrorDiagnostics.snapshot(error) }
            condition.broadcast()
        }
        publicationClock.signal()
    }

    func close() {
        condition.withLock {
            publisher?.close()
            for window in windows.values { window.relay.closePublications() }
            store?.close()
            condition.broadcast()
        }
    }
}
