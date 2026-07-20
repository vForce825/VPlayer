// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation

public struct FieldMetadataReader: Sendable {
    public init() {}

    public func read(
        formatDescription: CMFormatDescription?,
        pixelBuffer: CVPixelBuffer?
    ) -> FieldMetadataEvidence {
        if let pixelBuffer {
            let level = MetadataLevel(
                count: CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferFieldCountKey,
                    nil
                ),
                detail: CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferFieldDetailKey,
                    nil
                )
            )
            if level.hasMetadata {
                return evidence(from: level, source: .pixelBuffer)
            }
        }

        if let formatDescription,
           let extensions = CMFormatDescriptionGetExtensions(formatDescription) {
            let level = MetadataLevel(
                count: value(for: kCVImageBufferFieldCountKey, in: extensions),
                detail: value(for: kCVImageBufferFieldDetailKey, in: extensions)
            )
            if level.hasMetadata {
                return evidence(from: level, source: .formatDescription)
            }
        }

        return FieldMetadataEvidence(fieldCount: nil, fieldOrder: nil, source: .none)
    }

    private func evidence(
        from level: MetadataLevel,
        source: FieldEvidenceSource
    ) -> FieldMetadataEvidence {
        let fieldCount = integer(from: level.count)
        guard fieldCount == 2,
              let parity = parity(from: level.detail) else {
            return FieldMetadataEvidence(
                fieldCount: fieldCount,
                fieldOrder: nil,
                source: source
            )
        }
        return FieldMetadataEvidence(
            fieldCount: fieldCount,
            fieldOrder: ResolvedFieldOrder(
                parity: parity,
                confidence: .signaled,
                source: source
            ),
            source: source
        )
    }

    private func value(
        for key: CFString,
        in dictionary: CFDictionary
    ) -> CFTypeRef? {
        guard let pointer = CFDictionaryGetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque()
        ) else {
            return nil
        }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
    }

    private func integer(from value: CFTypeRef?) -> Int? {
        guard let value,
              CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        let number = unsafeDowncast(value, to: CFNumber.self)
        var result: Double = 0
        guard CFNumberGetValue(number, .doubleType, &result),
              result.isFinite,
              result.rounded() == result,
              result >= Double(Int32.min),
              result <= Double(Int32.max) else {
            return nil
        }
        return Int(result)
    }

    private func parity(from value: CFTypeRef?) -> FieldParity? {
        guard let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        if CFEqual(value, kCVImageBufferFieldDetailTemporalTopFirst) {
            return .top
        }
        if CFEqual(value, kCVImageBufferFieldDetailTemporalBottomFirst) {
            return .bottom
        }
        if CFEqual(value, kCVImageBufferFieldDetailSpatialFirstLineEarly) {
            return .top
        }
        if CFEqual(value, kCVImageBufferFieldDetailSpatialFirstLineLate) {
            return .bottom
        }
        return nil
    }
}

private struct MetadataLevel {
    let count: CFTypeRef?
    let detail: CFTypeRef?

    var hasMetadata: Bool {
        count != nil || detail != nil
    }
}
