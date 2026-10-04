// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

/// Immutable ownership bridge from the playback executor to a Receiver actor.
/// Only a copied header is passed to the SDK's `sending` initializer. The media
/// backing remains read-only, and all decoder-control attachments are preserved.
struct RendererReceiverSample: @unchecked Sendable {
    let buffer: CMSampleBuffer

    func makeReady() throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
            sampleBuffer: buffer, sampleBufferOut: &copied)
        guard status == noErr, let copied, CMSampleBufferDataIsReady(copied) else {
            throw NSError(domain: "VPlayer.RendererReceiver.Sample", code: Int(status == noErr ? -1 : status))
        }
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                target: buffer, attachmentMode: mode) {
                CMSetAttachments(copied, attachments: attachments, attachmentMode: mode)
            }
        }
        // The C out parameter has no region-ownership annotation; CreateCopy
        // above creates an independent header. No other alias leaves this scope.
        nonisolated(unsafe) let header = copied
        return CMReadySampleBuffer(unsafeBuffer: header)
    }
}
