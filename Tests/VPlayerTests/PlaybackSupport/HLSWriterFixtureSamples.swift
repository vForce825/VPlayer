// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

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
