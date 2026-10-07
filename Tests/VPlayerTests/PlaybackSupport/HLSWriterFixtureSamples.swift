// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

/// Matches the acceptance reader's marker/media contract. A marker is a typed,
/// payload-free event, not a video frame. Positive-duration empty edits still fail.
/// https://developer.apple.com/documentation/coremedia/cmsamplebuffer/contenttype-swift.enum/markeronly
/// https://developer.apple.com/videos/play/wwdc2020/10090/ (8:57).
struct HLSFixtureVideoReaderCursor {
    enum Kind { case compressed, decoded }
    struct Snapshot {
        var count: Int
        var contentType: CMSampleBuffer.ContentType
        var duration: CMTime
        var valid = true
        var ready = true
        var totalSize = 0
        var blockSize: Int?
        var hasImage = false
        var hasFormat = false
    }
    static let maximumConsecutiveMarkers = 8
    let kind: Kind
    private(set) var skippedMarkers = 0
    private(set) var consecutiveMarkers = 0
    private(set) var mediaSamples = 0

    init(kind: Kind) { self.kind = kind }

    mutating func consumesMedia(_ ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) throws -> Bool {
        let contentType = ready.contentType
        let snapshot = ready.withUnsafeSampleBuffer { sample in
            Snapshot(count: CMSampleBufferGetNumSamples(sample), contentType: contentType,
                duration: CMSampleBufferGetDuration(sample), valid: CMSampleBufferIsValid(sample),
                ready: CMSampleBufferDataIsReady(sample), totalSize: CMSampleBufferGetTotalSampleSize(sample),
                blockSize: CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) },
                hasImage: CMSampleBufferGetImageBuffer(sample) != nil,
                hasFormat: CMSampleBufferGetFormatDescription(sample) != nil)
        }
        return try consumesMedia(snapshot)
    }

    mutating func consumesMedia(_ sample: Snapshot) throws -> Bool {
        func invalid(_ reason: String) -> NSError {
            NSError(domain: "HLSFixtureVideoReader", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(kind) ordinal=\(mediaSamples) \(reason); count=\(sample.count) " +
                "content=\(sample.contentType) bytes=\(sample.totalSize) block=\(String(describing: sample.blockSize)) " +
                "image=\(sample.hasImage) format=\(sample.hasFormat) duration=\(hlsFixtureTimeDescription(sample.duration))"])
        }
        guard sample.valid, sample.ready, sample.count >= 0 else {
            throw invalid("invalid sample buffer")
        }
        if sample.count == 0 {
            guard sample.contentType == .markerOnly, sample.totalSize == 0,
                  sample.blockSize == nil, !sample.hasImage, !sample.hasFormat,
                  !sample.duration.isValid || (sample.duration.isNumeric && sample.duration.epoch == 0 &&
                      sample.duration.value == 0) else {
                throw invalid("empty buffer carries media or duration")
            }
            guard consecutiveMarkers < Self.maximumConsecutiveMarkers else {
                throw invalid("marker run exceeds \(Self.maximumConsecutiveMarkers)")
            }
            consecutiveMarkers += 1
            skippedMarkers += 1
            return false
        }
        guard sample.count == 1, sample.hasFormat else {
            throw invalid("expected exactly one formatted media sample")
        }
        switch kind {
        case .compressed:
            guard sample.contentType == .dataBuffer, !sample.hasImage, sample.totalSize > 0,
                  let blockSize = sample.blockSize, blockSize >= sample.totalSize else {
                throw invalid("inconsistent compressed payload")
            }
        case .decoded:
            guard sample.contentType == .pixelBuffer, sample.hasImage, sample.blockSize == nil else {
                throw invalid("missing sole image payload")
            }
        }
        consecutiveMarkers = 0
        mediaSamples += 1
        return true
    }
}

func hlsFixtureTimeDescription(_ time: CMTime) -> String {
    "\(time.value)/\(time.timescale),epoch=\(time.epoch),flags=\(time.flags.rawValue)"
}

/// Keep fixture source headers available for assertions while the receiver owns a fresh header.
func makeReadyWriterFixtureSample(
    copying sample: CMSampleBuffer
) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
    var copied: CMSampleBuffer?
    let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
        sampleBuffer: sample, sampleBufferOut: &copied)
    guard status == noErr, let copied, CMSampleBufferDataIsReady(copied) else {
        throw NSError(domain: NSOSStatusErrorDomain,
            code: Int(status == noErr ? kCMSampleBufferError_BufferNotReady : status))
    }
    for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
        if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
            target: sample, attachmentMode: mode) {
            CMSetAttachments(copied, attachments: attachments, attachmentMode: mode)
        }
    }
    // The C out-pointer lacks ownership annotations; CreateCopy returned a new header.
    // Media backing stays read-only and the source samples remain alive through append.
    nonisolated(unsafe) let nativeHeader = copied
    return CMReadySampleBuffer(unsafeBuffer: nativeHeader)
}

/// Own a legacy header before leaving the typed reader payload's unsafe borrow.
func makeOwnedReaderFixtureSample(
    copying ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
) throws -> CMSampleBuffer {
    try ready.withUnsafeSampleBuffer { sample in
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleBufferOut: &copied)
        guard status == noErr, let copied, CMSampleBufferDataIsReady(copied) else {
            throw NSError(domain: NSOSStatusErrorDomain,
                code: Int(status == noErr ? kCMSampleBufferError_BufferNotReady : status))
        }
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                target: sample, attachmentMode: mode) {
                CMSetAttachments(copied, attachments: attachments, attachmentMode: mode)
            }
        }
        // C does not annotate the new header returned through this out-pointer.
        nonisolated(unsafe) let ownedHeader = copied
        return ownedHeader
    }
}
