// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum SystemHLSPublicationGraphFailure: Error, Sendable {
    case receive(logicalSequence: UInt64, mediaType: FinalFMP4MediaType,
                 range: FMP4PresentationRange?, commonStart: ExactMediaTime?,
                 accessUnitDuration: ExactMediaTime?, underlying: String)
}

/// 同一 item 的 writer→validator→publisher→store 汇合点。所有 readiness 都来自
/// `HLSPublicationCoordinator.visible`，不会用 packet 数或布尔标志伪造三秒前缀。
final class SystemHLSPublicationGraph: @unchecked Sendable {
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
    private var windows: [UInt64: Window] = [:]
    private var initialWriterIDs: [UInt64] = []
    private var currentByParticipant: [UInt64: Window] = [:]
    private var storedError: Error?
    private var naturalEndPending = false
    private var prefixUnavailableAtNaturalEnd = false
    private var lastLogicalSequence: UInt64 = 0
    private var videoFrameRateMilli: UInt64?
    private(set) var store: SealedMediaStore?
    private(set) var declaration: HLSItemDeclaration?
    private(set) var publisher: HLSPublicationCoordinator?

    init(itemGeneration: UInt64,
         publicationDeadlineNanoseconds: Int64 = 120_000_000_000) throws {
        guard publicationDeadlineNanoseconds > 0 else {
            throw HLSPublicationFailure.invalidDuration
        }
        self.itemGeneration = itemGeneration
        self.publicationDeadlineNanoseconds = publicationDeadlineNanoseconds
        token = try LoopbackSessionToken.generateSystemCapability()
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
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
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
            storedError = SystemHLSPublicationGraphFailure.receive(
                logicalSequence: object.logicalSequence,
                mediaType: window.mediaType,
                range: try? FMP4PresentationRange.inspect(
                    report: object.report, mediaType: window.mediaType),
                commonStart: object.publicationEvidence?.boundary?.commonStart,
                accessUnitDuration: object.publicationEvidence?.boundary?.accessUnitDuration,
                underlying: String(reflecting: error))
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
            initialWindowMinimumSeconds: 3)
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
    /// 唯一 natural-end CAS；不能把尾片当普通中段提前发布。
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

    func finishNaturalEnd() throws {
        try condition.withLock {
            if let storedError { throw storedError }
            guard let publisher else { throw HLSPublicationFailure.identityMismatch }
            let result = try publisher.publish(
                ticket: publisher.ticket,
                now: Int64(lastLogicalSequence + 2) * 1_000_000_000,
                naturalEnd: true)
            if case .waiting = result, publisher.visible == nil {
                prefixUnavailableAtNaturalEnd = true
            }
            naturalEndPending = false
            condition.broadcast()
        }
    }

    func recordFailure(_ error: Error) {
        condition.withLock {
            if storedError == nil { storedError = error }
            condition.broadcast()
        }
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
