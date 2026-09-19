// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import Darwin
import Foundation
import XCTest
@testable import VPlayerPlayback

struct ReleasePacket {
    let object: SealedMediaObject
    let receipt: SegmentValidationReceipt
    let relay: SegmentReportRelay
}

final class ReleaseSystemSink: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [SealedMediaObject] = []

    init() {}

    func collect(_ object: SealedMediaObject) {
        lock.withLock { objects.append(object) }
    }

    func take(_ kind: SealedMediaObjectKind) -> SealedMediaObject? {
        lock.withLock {
            guard let index = objects.firstIndex(where: { $0.kind == kind }) else {
                return nil
            }
            return objects.remove(at: index)
        }
    }
}

enum ReleaseFixtureValues {
    static let token = "0123456789abcdef0123456789abcdef"

    static func time(_ value: Int64, _ scale: Int32 = 1) -> ExactMediaTime {
        .init(value: value, timescale: scale)
    }

    static func binding(id: UInt64 = 2, epoch: UInt64 = 1,
                        writer: UInt64, item: UInt64 = 19) throws -> FMP4WriterBinding {
        let lifecycle = try ReleaseIdentityFixture.lifecycle(
            using: PlaybackIdentityAllocator.shared)
        return FMP4WriterBinding(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: .init(rawValue: item),
            mediaEpoch: .init(rawValue: epoch),
            publicationParticipantID: .init(rawValue: id),
            renditionIdentity: .init(rawValue: id),
            writerIdentity: .init(rawValue: writer))
    }

    static func declaration(
        itemGeneration: UInt64 = 19,
        renditionID: String = "aac-2"
    ) throws -> HLSItemDeclaration {
        HLSItemDeclaration(
            itemGeneration: itemGeneration,
            token: token,
            video: nil,
            audio: [.init(participantID: 2, renditionID: renditionID,
                          codec: .aac, channels: 2, language: nil,
                          score: 100, peakEnvelope: 264_000)])
    }
}

final class ReleaseAACSeed: @unchecked Sendable {
    let relay: SegmentReportRelay
    let initialization: SealedMediaObject
    let proof: EpochFormatProof
    let packets: [ReleasePacket]
    let endpointAuthority: AACEffectiveEndpointAuthority
    var endpoint: AACEffectiveEndpointReceipt { endpointAuthority.receipt }
    let commonBoundaries: [ExactMediaTime]
    let liveEdge: ExactMediaTime
    fileprivate let encodedBuffers: [CMSampleBuffer]
    fileprivate let streamSummary: AACStreamSummary

    fileprivate init(relay: SegmentReportRelay, initialization: SealedMediaObject,
                 proof: EpochFormatProof, packets: [ReleasePacket],
                 endpointAuthority: AACEffectiveEndpointAuthority,
                 encodedBuffers: [CMSampleBuffer], streamSummary: AACStreamSummary) throws {
        self.relay = relay
        self.initialization = initialization
        self.proof = proof
        self.packets = packets
        self.endpointAuthority = endpointAuthority
        self.encodedBuffers = encodedBuffers
        self.streamSummary = streamSummary
        let effectiveEnd = endpointAuthority.receipt.lastEffectiveEnd
        let latestThreeSecondBoundary = try effectiveEnd.subtracting(
            ExactMediaTime(value: 3, timescale: 1)
        )
        commonBoundaries = Array(Set(
            packets.map(\.receipt.presentationRange.start) + [latestThreeSecondBoundary]
        )).sorted { CMTimeCompare($0.cmTime, $1.cmTime) < 0 }
        // PublicationCoverage 的共同末端必须是可呈现有效端点；writer 物理尾端 Q
        // 含 AAC trailing prime，不能拿来计算 E-3 秒的 prepared playhead。
        liveEdge = effectiveEnd
    }

    static func make(itemGeneration: UInt64 = 19,
                     outputLifecycleEpoch: OutputLifecycleEpoch? = nil,
                     layoutLabels: [RenditionChannelLabel] = [.l, .r]) async throws
        -> ReleaseAACSeed {
        try await makePending(itemGeneration: itemGeneration,
                              outputLifecycleEpoch: outputLifecycleEpoch,
                              layoutLabels: layoutLabels).finish()
    }

    private static func makeEncodedTemplate(
        layoutLabels: [RenditionChannelLabel]
    ) async throws -> ReleaseAACEncodedTemplate {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: layoutLabels),
            capabilityVersion: "task21-real-avplayer-v1")
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let channelCount = layoutLabels.count
        let maximumFramesPerChunk = channelCount == 0 ? 0 : 32_768 / channelCount
        guard maximumFramesPerChunk > 0 else {
            throw AACRenditionFailure.invalidLayout
        }
        var remainingFrames = 8 * 48_000
        var sourceFrame = 0
        var encoded: [CMSampleBuffer] = []
        let summary = try encoder.encodeStream(nextPCM: {
            guard remainingFrames > 0 else { return nil }
            let frames = min(8_192, maximumFramesPerChunk, remainingFrames)
            remainingFrames -= frames
            defer { sourceFrame += frames }
            var samples: [Float] = []
            samples.reserveCapacity(frames * channelCount)
            for offset in 0..<frames {
                let value = sin(Float(sourceFrame + offset) * 0.03125) * 0.2
                for channel in 0..<channelCount {
                    // 每个真实声道都由 encoder 消费；轻微的确定性增益差异避免
                    // 6ch 夹具退化成只复制 stereo payload 的伪多声道格式。
                    samples.append(value * Float(channel + 1)
                        / Float(channelCount))
                }
            }
            return samples
        }, append: { encoded.append($0) })
        guard let firstEncoded = encoded.first else {
            throw AACRenditionFailure.invalidInput
        }
        let firstPhysicalStart = CMSampleBufferGetPresentationTimeStamp(firstEncoded)
        var secondBuckets: [[CMSampleBuffer]] = []
        for buffer in encoded {
            let relative = CMTimeSubtract(
                CMSampleBufferGetPresentationTimeStamp(buffer),
                firstPhysicalStart
            )
            let second = max(0, Int(floor(CMTimeGetSeconds(relative))))
            while secondBuckets.count <= second { secondBuckets.append([]) }
            secondBuckets[second].append(buffer)
        }
        let coalesced = try secondBuckets.filter { !$0.isEmpty }.map(coalesce)
        guard let format = CMSampleBufferGetFormatDescription(
            try XCTUnwrap(coalesced.first)
        ) else {
            throw AACRenditionFailure.invalidInput
        }
        let frozenBuffers = try coalesced.map(freezeEncodedBuffer)
        calibrator.cancel()
        try calibrator.finishOnOwnedRunner()
        return ReleaseAACEncodedTemplate(format: format, buffers: frozenBuffers,
                                        streamSummary: summary)
    }

    private static func encodedTemplate(
        layoutLabels: [RenditionChannelLabel]
    ) async throws -> ReleaseAACEncodedTemplate {
        guard layoutLabels == [.l, .r] else {
            throw AACRenditionFailure.invalidLayout
        }
        return try await makeEncodedTemplate(layoutLabels: layoutLabels)
    }

    fileprivate static func makePending(
        itemGeneration: UInt64 = 19,
        outputLifecycleEpoch: OutputLifecycleEpoch? = nil,
        layoutLabels: [RenditionChannelLabel] = [.l, .r]
    ) async throws
        -> ReleasePendingAACSeed {
        let template = try await encodedTemplate(layoutLabels: layoutLabels)
        let coalesced = try template.buffers.map {
            try makeEncodedBuffer(from: $0, format: template.format)
        }
        let summary = template.streamSummary
        let workspace = AACCalibrationWorkspace()
        let payloadBytes = coalesced.reduce(0) {
            $0 + (CMSampleBufferGetDataBuffer($1).map(CMBlockBufferGetDataLength) ?? 0)
        }
        let epoch = AACEncodedEpoch(identity: summary.identity, buffers: coalesced,
            realSampleCount: Int(summary.realSampleCount),
            totalDecodedFrames: Int(summary.totalDecodedFrames),
            leadingFrames: summary.leadingFrames,
            trailingFrames: Int(summary.trailingFrames),
            actualLeadingPrimeFrames: summary.actualLeadingPrimeFrames,
            actualTrailingPrimeFrames: summary.actualTrailingPrimeFrames,
            bandwidth: summary.bandwidth,
            packetLease: try workspace.acquire(.aacPackets, bytes: payloadBytes),
            formatLease: try workspace.acquire(.nonPayload, bytes: 8_192))
        guard epoch.buffers.count <= 8,
              let first = epoch.buffers.first,
              let format = CMSampleBufferGetFormatDescription(first) else {
            throw AACRenditionFailure.capacityExceeded
        }
        let effectiveStart = CMSampleBufferGetOutputPresentationTimeStamp(first)
        let physicalStart = CMSampleBufferGetPresentationTimeStamp(first)
        let fallback = try ReleaseFixtureValues.binding(id: 2, epoch: 1,
            writer: try PlaybackIdentityAllocator.shared.next(in: .nonce),
            item: itemGeneration)
        let binding = FMP4WriterBinding(
            outputLifecycleEpoch: outputLifecycleEpoch ?? fallback.outputLifecycleEpoch,
            itemGeneration: fallback.itemGeneration,
            mediaEpoch: fallback.mediaEpoch,
            publicationParticipantID: fallback.publicationParticipantID,
            renditionIdentity: fallback.renditionIdentity,
            writerIdentity: fallback.writerIdentity)
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: physicalStart))
        try boundary.registerAudioRendition(binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: physicalStart)
        let sink = ReleaseSystemSink()
        let relay = SegmentReportRelay(binding: binding, limits: .audio,
            capacity: 8, objectSink: sink.collect)
        let writer = try SegmentedFMP4Writer(binding: binding, trackKind: .aac,
            sourceFormatHint: format, boundarySession: boundary.session,
            compressedFormatConfiguration: nil,
            ownershipLimits: .init(rolloverThreshold: 256, hardCapacity: 384),
            relay: relay, systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        try writer.start(at: effectiveStart)
        try writer.appendAACEncodedEpoch(epoch, coordinator: boundary)
        return ReleasePendingAACSeed(
            writer: writer, sink: sink, relay: relay, epoch: epoch,
            encodedBuffers: coalesced, streamSummary: summary)
    }

    fileprivate static func finish(_ pending: ReleasePendingAACSeed) async throws
        -> ReleaseAACSeed {
        try (await pending.finishWriter()).sealEndpoint()
    }

    /// 只在一个正式的一秒共同边界内部合并 packet；边界后的首个 AU 因而仍落在
    /// `SegmentBoundaryCoordinator` 接受的单个 AAC sample 窗口内。
    private static func coalesce(_ buffers: [CMSampleBuffer]) throws -> CMSampleBuffer {
        guard let first = buffers.first,
              let format = CMSampleBufferGetFormatDescription(first) else {
            throw AACRenditionFailure.invalidInput
        }
        var payload = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        for buffer in buffers {
            guard let candidate = CMSampleBufferGetFormatDescription(buffer),
                  CMFormatDescriptionEqual(candidate, otherFormatDescription: format),
                  let block = CMSampleBufferGetDataBuffer(buffer) else {
                throw AACRenditionFailure.invalidInput
            }
            var pointer: UnsafePointer<AudioStreamPacketDescription>?
            var descriptionBytes = 0
            try AACRenditionEncoder.check(
                CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
                    buffer,
                    packetDescriptionsPointerOut: &pointer,
                    sizeOut: &descriptionBytes
                )
            )
            guard let pointer,
                  descriptionBytes == CMSampleBufferGetNumSamples(buffer)
                    * MemoryLayout<AudioStreamPacketDescription>.stride else {
                throw AACRenditionFailure.invalidInput
            }
            for index in 0..<CMSampleBufferGetNumSamples(buffer) {
                var description = pointer[index]
                let byteCount = Int(description.mDataByteSize)
                var bytes = Data(count: byteCount)
                try bytes.withUnsafeMutableBytes { destination in
                    try AACRenditionEncoder.check(CMBlockBufferCopyDataBytes(
                        block,
                        atOffset: Int(description.mStartOffset),
                        dataLength: byteCount,
                        destination: destination.baseAddress!
                    ))
                }
                description.mStartOffset = Int64(payload.count)
                descriptions.append(description)
                payload.append(bytes)
            }
        }
        var block: CMBlockBuffer?
        try AACRenditionEncoder.check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        ))
        try payload.withUnsafeBytes { source in
            try AACRenditionEncoder.check(CMBlockBufferReplaceDataBytes(
                with: source.baseAddress!,
                blockBuffer: try XCTUnwrap(block),
                offsetIntoDestination: 0,
                dataLength: payload.count
            ))
        }
        var result: CMSampleBuffer?
        try AACRenditionEncoder.check(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(block),
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: descriptions.count,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(first),
            packetDescriptions: descriptions,
            sampleBufferOut: &result
        ))
        let combined = try XCTUnwrap(result)
        try AACRenditionEncoder.check(CMSampleBufferSetOutputPresentationTimeStamp(
            combined,
            newValue: CMSampleBufferGetOutputPresentationTimeStamp(first)
        ))
        if let leading = CMGetAttachment(
            first,
            key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            attachmentModeOut: nil
        ) {
            CMSetAttachment(
                combined,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                value: leading,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        if let last = buffers.last,
           let trailing = CMGetAttachment(
               last,
               key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
               attachmentModeOut: nil
           ) {
            CMSetAttachment(
                combined,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                value: trailing,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        return combined
    }

    private static func freezeEncodedBuffer(_ buffer: CMSampleBuffer) throws
        -> ReleaseAACEncodedBufferTemplate {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else {
            throw AACRenditionFailure.invalidInput
        }
        let byteCount = CMBlockBufferGetDataLength(block)
        var payload = Data(count: byteCount)
        try payload.withUnsafeMutableBytes { destination in
            try AACRenditionEncoder.check(CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination.baseAddress!
            ))
        }
        var pointer: UnsafePointer<AudioStreamPacketDescription>?
        var descriptionBytes = 0
        try AACRenditionEncoder.check(
            CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
                buffer,
                packetDescriptionsPointerOut: &pointer,
                sizeOut: &descriptionBytes
            )
        )
        let sampleCount = CMSampleBufferGetNumSamples(buffer)
        guard let pointer,
              descriptionBytes == sampleCount
                * MemoryLayout<AudioStreamPacketDescription>.stride else {
            throw AACRenditionFailure.invalidInput
        }
        let descriptions = Array(UnsafeBufferPointer(start: pointer, count: sampleCount))
        return ReleaseAACEncodedBufferTemplate(
            payload: payload,
            packetDescriptions: descriptions,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
            outputPresentationTimeStamp:
                CMSampleBufferGetOutputPresentationTimeStamp(buffer),
            leadingTrim: trimTime(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart),
            trailingTrim: trimTime(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd))
    }

    private static func makeEncodedBuffer(
        from template: ReleaseAACEncodedBufferTemplate,
        format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        try AACRenditionEncoder.check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: template.payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: template.payload.count,
            flags: 0,
            blockBufferOut: &block
        ))
        try template.payload.withUnsafeBytes { source in
            try AACRenditionEncoder.check(CMBlockBufferReplaceDataBytes(
                with: source.baseAddress!,
                blockBuffer: try XCTUnwrap(block),
                offsetIntoDestination: 0,
                dataLength: template.payload.count
            ))
        }
        var result: CMSampleBuffer?
        try AACRenditionEncoder.check(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(block),
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: template.packetDescriptions.count,
            presentationTimeStamp: template.presentationTimeStamp,
            packetDescriptions: template.packetDescriptions,
            sampleBufferOut: &result
        ))
        let buffer = try XCTUnwrap(result)
        try AACRenditionEncoder.check(CMSampleBufferSetOutputPresentationTimeStamp(
            buffer, newValue: template.outputPresentationTimeStamp
        ))
        if let leadingTrim = template.leadingTrim {
            CMSetAttachment(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                value: CMTimeCopyAsDictionary(leadingTrim,
                    allocator: kCFAllocatorDefault)!,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        if let trailingTrim = template.trailingTrim {
            CMSetAttachment(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                value: CMTimeCopyAsDictionary(trailingTrim,
                    allocator: kCFAllocatorDefault)!,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return buffer
    }

    fileprivate static func trimTime(_ buffer: CMSampleBuffer,
                                     key: CFString) -> CMTime? {
        guard let value = CMGetAttachment(buffer, key: key,
                                          attachmentModeOut: nil) else {
            return nil
        }
        guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
        let time = CMTimeMakeFromDictionary((value as! CFDictionary))
        return time.isValid ? time : nil
    }

}

private struct ReleaseAACEncodedBufferTemplate: @unchecked Sendable {
    let payload: Data
    let packetDescriptions: [AudioStreamPacketDescription]
    let presentationTimeStamp: CMTime
    let outputPresentationTimeStamp: CMTime
    let leadingTrim: CMTime?
    let trailingTrim: CMTime?
}

private final class ReleaseAACEncodedTemplate: @unchecked Sendable {
    let format: CMAudioFormatDescription
    let buffers: [ReleaseAACEncodedBufferTemplate]
    let streamSummary: AACStreamSummary

    init(format: CMAudioFormatDescription,
         buffers: [ReleaseAACEncodedBufferTemplate],
         streamSummary: AACStreamSummary) {
        self.format = format
        self.buffers = buffers
        self.streamSummary = streamSummary
    }
}

private final class ReleasePendingAACSeed: @unchecked Sendable {
    let writer: SegmentedFMP4Writer
    let sink: ReleaseSystemSink
    let relay: SegmentReportRelay
    let epoch: AACEncodedEpoch
    let encodedBuffers: [CMSampleBuffer]
    let streamSummary: AACStreamSummary

    init(writer: SegmentedFMP4Writer, sink: ReleaseSystemSink,
         relay: SegmentReportRelay, epoch: AACEncodedEpoch,
         encodedBuffers: [CMSampleBuffer], streamSummary: AACStreamSummary) {
        self.writer = writer
        self.sink = sink
        self.relay = relay
        self.epoch = epoch
        self.encodedBuffers = encodedBuffers
        self.streamSummary = streamSummary
    }

    var terminalBinding: AACWriterTerminalBinding {
        get throws { try XCTUnwrap(writer.aacTerminalBinding) }
    }

    func finish() async throws -> ReleaseAACSeed {
        try await ReleaseAACSeed.finish(self)
    }

    func finishWriter() async throws -> ReleaseFinishedAACSeed {
        _ = try await writer.finish()
        let initialization = try XCTUnwrap(sink.take(.initialization))
        var media: [SealedMediaObject] = []
        while let object = sink.take(.media) { media.append(object) }
        guard media.count >= 6 else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let proof = try FinalFMP4Validator(binding: writer.binding, mediaType: .audio)
            .validateInitialization(initialization)
        let timeline = SegmentTimelineValidator(proof: proof)
        let packets = try media.map { object in
            ReleasePacket(object: object,
                receipt: try timeline.validate(object, using: proof), relay: relay)
        }
        return ReleaseFinishedAACSeed(
            writer: writer, relay: relay, epoch: epoch,
            initialization: initialization, media: media, proof: proof,
            packets: packets, encodedBuffers: encodedBuffers,
            streamSummary: streamSummary)
    }
}

private final class ReleaseFinishedAACSeed: @unchecked Sendable {
    let writer: SegmentedFMP4Writer
    let relay: SegmentReportRelay
    let epoch: AACEncodedEpoch
    let initialization: SealedMediaObject
    let media: [SealedMediaObject]
    let proof: EpochFormatProof
    let packets: [ReleasePacket]
    let encodedBuffers: [CMSampleBuffer]
    let streamSummary: AACStreamSummary

    init(writer: SegmentedFMP4Writer, relay: SegmentReportRelay,
         epoch: AACEncodedEpoch, initialization: SealedMediaObject,
         media: [SealedMediaObject], proof: EpochFormatProof,
         packets: [ReleasePacket], encodedBuffers: [CMSampleBuffer],
         streamSummary: AACStreamSummary) {
        self.writer = writer
        self.relay = relay
        self.epoch = epoch
        self.initialization = initialization
        self.media = media
        self.proof = proof
        self.packets = packets
        self.encodedBuffers = encodedBuffers
        self.streamSummary = streamSummary
    }

    func sealEndpoint() throws -> ReleaseAACSeed {
        let authority = try writer.makeAACEffectiveEndpointAuthority(
            epoch: epoch, initializationObject: initialization,
            mediaObjects: media)
        return try ReleaseAACSeed(
            relay: relay, initialization: initialization, proof: proof,
            packets: packets, endpointAuthority: authority,
            encodedBuffers: encodedBuffers, streamSummary: streamSummary)
    }
}


final class ReleaseHLSHarness: @unchecked Sendable {
    let store: SealedMediaStore
    let seed: ReleaseAACSeed
    let publisher: HLSPublicationCoordinator
    let declaration: HLSItemDeclaration

    init(token: LoopbackSessionToken, seed: ReleaseAACSeed,
         itemGeneration: UInt64 = 19, renditionID: String = "aac-2") throws {
        self.seed = seed
        store = SealedMediaStore(loopbackSession: token, itemGeneration: itemGeneration)
        var declared = try ReleaseFixtureValues.declaration(
            itemGeneration: itemGeneration, renditionID: renditionID)
        declared.token = token.value
        declaration = declared
        let candidate = try store.registerAudioCandidate(
            initialization: seed.initialization,
            proof: seed.proof,
            declaration: declared)
        publisher = try HLSPublicationCoordinator(
            store: store,
            participants: [.init(
                initialization: seed.initialization,
                proof: seed.proof,
                relay: seed.relay,
                candidateTicket: candidate.ticket,
                candidate: candidate,
                aacTerminalBinding: seed.endpointAuthority.terminalBinding)],
            declaration: declared,
            anchor: .init(mediaOrigin: ReleaseFixtureValues.time(0),
                          utcMilliseconds: 1_788_912_000_000))
        for (index, packet) in seed.packets.enumerated() {
            _ = try publisher.offer(
                packet.object,
                receipt: packet.receipt,
                relay: packet.relay,
                ticket: publisher.ticket,
                now: index >= 6 ? 1_000_000_000 : 0)
        }
        var now: Int64 = 1_000_000_000
        var reachedEnd = false
        for _ in 0..<8 {
            _ = try publisher.publish(
                ticket: publisher.ticket, now: now, naturalEnd: true)
            if publisher.visible?.media.values.allSatisfy({
                $0.text.hasSuffix("#EXT-X-ENDLIST\n")
            }) == true {
                reachedEnd = true
                break
            }
            now += 1_000_000_000
        }
        guard reachedEnd else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }
}

final class ReleaseLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

func releaseWaitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    } while Date() < deadline
    return condition()
}

final class ReleaseAACPublicationFixture: @unchecked Sendable {
    private enum TeardownState {
        case active
        case running
        case finished(Result<Void, ReleaseFixtureTeardownError>)
    }

    let server: LoopbackHTTPServer
    let source: LoopbackAVPlayerPreparationEvidenceSource
    let request: AVPlayerItemPreparationRequest
    let publication: ReleaseHLSHarness
    let endpointAuthority: AACEffectiveEndpointAuthority
    private let teardownLock = NSLock()
    private var teardownState = TeardownState.active
    private var teardownAttempts = 0

    private init(server: LoopbackHTTPServer,
                 source: LoopbackAVPlayerPreparationEvidenceSource,
                 request: AVPlayerItemPreparationRequest,
                 publication: ReleaseHLSHarness,
                 endpointAuthority: AACEffectiveEndpointAuthority) {
        self.server = server
        self.source = source
        self.request = request
        self.publication = publication
        self.endpointAuthority = endpointAuthority
    }

    static func make(
        lifecycle: OutputLifecycleEpoch,
        itemGeneration: UInt64 = 19,
        renditionID: String = "aac-2"
    ) async throws
        -> ReleaseAACPublicationFixture {
        let seed = try await ReleaseAACSeed.make(
            itemGeneration: itemGeneration, outputLifecycleEpoch: lifecycle)
        let box = ReleaseLockedValue<ReleaseHLSHarness>()
        let server = try await LoopbackHTTPSessionFactory().start(
            itemGeneration: itemGeneration,
            now: { 0 },
            logger: { _ in },
            responseFailure: { _, _ in }
        ) { token in
            let publication = try ReleaseHLSHarness(
                token: token, seed: seed, itemGeneration: itemGeneration,
                renditionID: renditionID)
            box.value = publication
            return LoopbackPreparedPublication(
                store: publication.store,
                declaration: publication.declaration,
                snapshot: try XCTUnwrap(publication.publisher.visible))
        }
        let publication = try XCTUnwrap(box.value)
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: server)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle, itemGeneration: itemGeneration)
        let bundle = try LoopbackAVPlayerPreparationBundle(
            evidenceSource: source, item: item)
        let snapshot = try XCTUnwrap(publication.publisher.visible)
        var urls = [bundle.request.itemURL]
        let participantIDs: [UInt64]
        if let direct = bundle.request.directAudioOnlyRendition {
            participantIDs = [direct.rawValue]
        } else {
            participantIDs = snapshot.participantVector.map(\.participantID)
            urls += try snapshot.participantVector.map { entry in
                let path = try entry.declaration.playlistURI(
                    participantID: entry.participantID)
                return try XCTUnwrap(
                    URL(string: path, relativeTo: server.baseURL)?.absoluteURL)
            }
        }
        for participantID in participantIDs {
            let media = try XCTUnwrap(snapshot.media[participantID])
            urls += try (media.initializationResources + media.resources).map { key in
                try XCTUnwrap(
                    URL(string: server.path(for: key),
                        relativeTo: server.baseURL)?.absoluteURL)
            }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for url in urls {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200, !body.isEmpty else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while server.currentAudioSelectionCapability(
            itemGeneration: itemGeneration,
            publicationSequence: bundle.request.publicationSequence
        ) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard server.currentAudioSelectionCapability(
            itemGeneration: itemGeneration,
            publicationSequence: bundle.request.publicationSequence
        ) != nil else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        return .init(
            server: server,
            source: source,
            request: bundle.request,
            publication: publication,
            endpointAuthority: seed.endpointAuthority)
    }

    func makePreparedPlayhead() async throws -> PreparedPlayheadIdentity {
        let readiness = try XCTUnwrap(source.consumeCompletedPublication(
            itemURL: request.itemURL,
            item: request.item,
            publicationSequence: request.publicationSequence))
        let selection = try XCTUnwrap(readiness.audioSelectionCapability)
        let consumedTimeline = try await source.consumePlayerItemTimelineMapping(
            endpointAuthority: endpointAuthority,
            itemURL: request.itemURL,
            item: request.item,
            publicationSequence: request.publicationSequence,
            selection: selection)
        let timeline = try XCTUnwrap(consumedTimeline)
        let lead = ExactMediaTime(value: 3, timescale: 1)
        let mediaTime = try XCTUnwrap(
            try timeline.mapping.latestBoundary(withLead: lead))
        return PreparedPlayheadIdentity(
            outputLifecycleEpoch: request.item.outputLifecycleEpoch,
            itemGeneration: request.item.itemGeneration,
            publicationSequence: request.publicationSequence,
            mediaTime: mediaTime,
            playerItemTime: try timeline.playerItemTime(for: mediaTime),
            seekNonce: 1,
            renditionSelectionSlotNonce: 2,
            audioSelectionCapability: selection,
            timelineMappingAuthority: timeline)
    }

    var teardownAttemptCount: Int {
        teardownLock.withLock { teardownAttempts }
    }

    func teardown() throws {
        let action: Result<Void, ReleaseFixtureTeardownError>? = teardownLock.withLock {
            switch teardownState {
            case .active:
                teardownState = .running
                teardownAttempts += 1
                return nil
            case .running:
                return .failure(.inProgress)
            case .finished(let result):
                return result
            }
        }
        if let action {
            return try action.get()
        }

        let result = performTeardown()
        teardownLock.withLock { teardownState = .finished(result) }
        try result.get()
    }

    private func performTeardown() -> Result<Void, ReleaseFixtureTeardownError> {
        source.retirePreparation()
        let ticket = server.closeAdmission()
        let becameIdle = releaseWaitUntil(timeout: 2) {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }
        var drainFailed = false
        var retireFailed = false
        do {
            try server.drain(cleanupTicket: ticket)
        } catch {
            drainFailed = true
        }
        do {
            try server.retire(cleanupTicket: ticket)
        } catch {
            retireFailed = true
        }
        if !becameIdle { return .failure(.idleTimeout) }
        switch (drainFailed, retireFailed) {
        case (false, false): return .success(())
        case (true, false): return .failure(.drainFailed)
        case (false, true): return .failure(.retireFailed)
        case (true, true): return .failure(.drainAndRetireFailed)
        }
    }

    deinit {
        // 显式 teardown 已留下固定终态时不重复触碰 server；这里只兜底异常退出。
        try? teardown()
    }
}

enum ReleaseFixtureTeardownError: Error, Equatable, Sendable {
    case idleTimeout
    case drainFailed
    case retireFailed
    case drainAndRetireFailed
    case inProgress
}
