// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreGraphics
import CoreMedia
import Metal
import QuartzCore
import XCTest
@testable import VPlayerPlayback

final class HDRPresentationPolicyTests: XCTestCase {
    func testUnknownSDRMetadataDefaultsToVideoRangeAndBT709() {
        let configuration = HDRPresentationPolicy.systemManaged.configuration(
            for: metadata(
                range: .unknown,
                matrix: .unknown,
                transfer: .unknown,
                primaries: .unknown
            )
        )

        XCTAssertEqual(configuration.range, .video)
        XCTAssertEqual(configuration.matrix, .bt709)
        XCTAssertEqual(configuration.transfer, .bt709)
        XCTAssertEqual(configuration.primaries, .bt709)
        XCTAssertFalse(configuration.isHDR)
        XCTAssertEqual(configuration.bitDepth, 8)
    }

    func testKnownSDRAndUnusualExplicitMetadataArePreserved() {
        let configuration = HDRPresentationPolicy.systemManaged.configuration(
            for: metadata(
                bitDepth: 10,
                range: .full,
                matrix: .bt601,
                transfer: .linear,
                primaries: .bt2020
            )
        )

        XCTAssertEqual(configuration.range, .full)
        XCTAssertEqual(configuration.matrix, .bt601)
        XCTAssertEqual(configuration.transfer, .linear)
        XCTAssertEqual(configuration.primaries, .bt2020)
        XCTAssertEqual(configuration.bitDepth, 10)
        XCTAssertFalse(configuration.isHDR)
    }

    func testPQAndHLGDefaultUnknownMatrixAndPrimariesToBT2020WithLinearOutputPolicy() {
        for transfer: VideoFormatMetadata.Transfer in [.pq, .hlg] {
            let configuration = HDRPresentationPolicy.systemManaged.configuration(
                for: metadata(
                    bitDepth: 10,
                    range: .unknown,
                    matrix: .unknown,
                    transfer: transfer,
                    primaries: .unknown
                )
            )

            XCTAssertEqual(configuration.range, .video)
            XCTAssertEqual(configuration.matrix, .bt2020)
            XCTAssertEqual(configuration.transfer, transfer)
            XCTAssertEqual(configuration.primaries, .bt2020)
            XCTAssertTrue(configuration.isHDR)
            XCTAssertEqual(configuration.bitDepth, 10)
            XCTAssertEqual(configuration.drawablePixelFormat, .rgba16Float)
            XCTAssertEqual(
                configuration.layerColorSpaceName,
                CGColorSpace.extendedLinearITUR_2020 as String
            )
            XCTAssertEqual(configuration.layerToneMapMode, .automatic)
        }
    }

    func testExplicitHDRMetadataIsNotOverwrittenBecauseItIsUnusual() {
        let configuration = HDRPresentationPolicy.systemManaged.configuration(
            for: metadata(
                range: .full,
                matrix: .bt601,
                transfer: .pq,
                primaries: .bt709
            )
        )

        XCTAssertEqual(configuration.range, .full)
        XCTAssertEqual(configuration.matrix, .bt601)
        XCTAssertEqual(configuration.transfer, .pq)
        XCTAssertEqual(configuration.primaries, .bt709)
        XCTAssertTrue(configuration.isHDR)
    }

    func testP010GeometryChromaLocationsAndHDRPayloadsSurviveExactly() {
        let aperture = CGRect(x: 4, y: 2, width: 3_832, height: 2_156)
        let chroma = VideoFormatMetadata.ChromaLocation(
            topField: "left",
            bottomField: "center"
        )
        let hdr = VideoFormatMetadata.HDRStaticMetadata(
            masteringDisplayColorVolume: Data([1, 3, 5, 7]),
            contentLightLevelInfo: Data([2, 4, 6])
        )

        let configuration = HDRPresentationPolicy.systemManaged.configuration(
            for: metadata(
                bitDepth: 10,
                transfer: .hlg,
                cleanAperture: aperture,
                chromaLocation: chroma,
                hdrStaticMetadata: hdr
            )
        )

        XCTAssertEqual(configuration.bitDepth, 10)
        XCTAssertEqual(configuration.cleanAperture, aperture)
        XCTAssertEqual(configuration.chromaLocation, chroma)
        XCTAssertEqual(configuration.hdrStaticMetadata, hdr)
        XCTAssertEqual(configuration.outputConfiguration.cleanAperture, aperture)
        XCTAssertEqual(configuration.outputConfiguration.chromaLocation, chroma)
        XCTAssertEqual(configuration.outputConfiguration.hdrStaticMetadata, hdr)
    }

    func testRendererUsesEffectiveUnknownSDRMetadataForShaderAndGPUUniforms() {
        let source = metadata(
            range: .unknown,
            matrix: .unknown,
            transfer: .unknown,
            primaries: .unknown
        )

        let state = MetalVideoRenderer.makeShaderState(
            metadata: source,
            pixelFormatIsTenBit: false
        )
        let uniforms = MetalVideoRenderer.makeGPUUniforms(
            shaderState: state,
            metadata: source
        )

        XCTAssertEqual(state.uniforms.matrixKind, .bt709)
        XCTAssertEqual(state.uniforms.transfer, .bt709)
        XCTAssertEqual(state.uniforms.primaries, .bt709)
        XCTAssertEqual(state.uniforms.yOffset, Float(16) / 255, accuracy: 0.000_001)
        XCTAssertEqual(uniforms.applyGamutTransform, 1)
    }

    private func metadata(
        bitDepth: Int = 8,
        range: VideoFormatMetadata.Range = .video,
        matrix: VideoFormatMetadata.Matrix = .unknown,
        transfer: VideoFormatMetadata.Transfer = .bt709,
        primaries: VideoFormatMetadata.Primaries = .unknown,
        cleanAperture: CGRect? = nil,
        chromaLocation: VideoFormatMetadata.ChromaLocation = .init(
            topField: nil,
            bottomField: nil
        ),
        hdrStaticMetadata: VideoFormatMetadata.HDRStaticMetadata = .init(
            masteringDisplayColorVolume: nil,
            contentLightLevelInfo: nil
        )
    ) -> VideoFormatMetadata {
        VideoFormatMetadata(
            dimensions: CMVideoDimensions(width: 3_840, height: 2_160),
            bitDepth: bitDepth,
            range: range,
            matrix: matrix,
            transfer: transfer,
            primaries: primaries,
            cleanAperture: cleanAperture,
            chromaLocation: chromaLocation,
            hdrStaticMetadata: hdrStaticMetadata
        )
    }
}
