// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreGraphics
import CoreMedia
import Foundation
import Metal
import QuartzCore

struct HDRPresentationConfiguration: Equatable {
    let dimensions: CMVideoDimensions
    let bitDepth: Int
    let range: VideoFormatMetadata.Range
    let matrix: VideoFormatMetadata.Matrix
    let transfer: VideoFormatMetadata.Transfer
    let primaries: VideoFormatMetadata.Primaries
    let isHDR: Bool
    let drawablePixelFormat: MTLPixelFormat
    let layerColorSpaceName: String
    let layerToneMapMode: CALayer.ToneMapMode
    let cleanAperture: CGRect?
    let chromaLocation: VideoFormatMetadata.ChromaLocation
    let hdrStaticMetadata: VideoFormatMetadata.HDRStaticMetadata

    var outputConfiguration: MetalOutputConfiguration {
        MetalOutputConfiguration(
            cleanAperture: cleanAperture,
            chromaLocation: chromaLocation,
            hdrStaticMetadata: hdrStaticMetadata
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dimensions.width == rhs.dimensions.width
            && lhs.dimensions.height == rhs.dimensions.height
            && lhs.bitDepth == rhs.bitDepth
            && lhs.range == rhs.range
            && lhs.matrix == rhs.matrix
            && lhs.transfer == rhs.transfer
            && lhs.primaries == rhs.primaries
            && lhs.isHDR == rhs.isHDR
            && lhs.drawablePixelFormat == rhs.drawablePixelFormat
            && lhs.layerColorSpaceName == rhs.layerColorSpaceName
            && lhs.layerToneMapMode == rhs.layerToneMapMode
            && lhs.cleanAperture == rhs.cleanAperture
            && lhs.chromaLocation == rhs.chromaLocation
            && lhs.hdrStaticMetadata == rhs.hdrStaticMetadata
    }
}

struct HDRPresentationPolicy: Sendable, Equatable {
    static let systemManaged = HDRPresentationPolicy()

    func configuration(for metadata: VideoFormatMetadata) -> HDRPresentationConfiguration {
        let isHDR = metadata.transfer == .pq || metadata.transfer == .hlg
        let effectiveRange: VideoFormatMetadata.Range = metadata.range == .unknown
            ? .video
            : metadata.range
        let defaultMatrix: VideoFormatMetadata.Matrix = isHDR ? .bt2020 : .bt709
        let effectiveMatrix = metadata.matrix == .unknown ? defaultMatrix : metadata.matrix
        let effectiveTransfer: VideoFormatMetadata.Transfer = metadata.transfer == .unknown
            ? .bt709
            : metadata.transfer
        let defaultPrimaries: VideoFormatMetadata.Primaries = isHDR ? .bt2020 : .bt709
        let effectivePrimaries = metadata.primaries == .unknown
            ? defaultPrimaries
            : metadata.primaries
        let copiedHDRMetadata = VideoFormatMetadata.HDRStaticMetadata(
            masteringDisplayColorVolume: metadata.hdrStaticMetadata.masteringDisplayColorVolume,
            contentLightLevelInfo: metadata.hdrStaticMetadata.contentLightLevelInfo
        )

        return HDRPresentationConfiguration(
            dimensions: metadata.dimensions,
            bitDepth: metadata.bitDepth,
            range: effectiveRange,
            matrix: effectiveMatrix,
            transfer: effectiveTransfer,
            primaries: effectivePrimaries,
            isHDR: isHDR,
            drawablePixelFormat: .rgba16Float,
            layerColorSpaceName: CGColorSpace.extendedLinearITUR_2020 as String,
            layerToneMapMode: .automatic,
            cleanAperture: metadata.cleanAperture,
            chromaLocation: metadata.chromaLocation,
            hdrStaticMetadata: copiedHDRMetadata
        )
    }

    @MainActor
    func configure(layer: CAMetalLayer) {
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        layer.toneMapMode = .automatic
    }
}
