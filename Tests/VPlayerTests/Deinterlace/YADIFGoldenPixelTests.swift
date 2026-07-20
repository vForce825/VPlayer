// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Metal
import XCTest
@testable import VPlayerPlayback

@MainActor
final class YADIFGoldenPixelTests: XCTestCase {
    private static let width = 64
    private static let height = 36
    private static let nv12BytesPerFrame = width * height * 3 / 2
    private static let p010BytesPerFrame = width * height * 3
    private static let lockedCommit = "38b88335f99e76ed89ff3c93f877fdefce736c13"
    private static let nv12SourceRecipe =
        "testsrc2=size=128x72:rate=50:duration=0.20,scale=64:36:flags=bilinear"
    private static let p010SourceRecipe =
        "testsrc2=size=128x72:rate=50:duration=0.20,format=yuv420p10le,scale=64:36:flags=bilinear"
    private static let nv12Graphs = GoldenManifest.FormatEntry.Graphs(
        tffInput: "format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\\,4)\\,0)+eq(mod(n\\,4)\\,3),weave=first_field=top,format=nv12",
        bffInput: "format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\\,4)\\,1)+eq(mod(n\\,4)\\,2),weave=first_field=bottom,format=nv12",
        tffOutput: "format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\\,4)\\,0)+eq(mod(n\\,4)\\,3),weave=first_field=top,yadif=mode=send_field:parity=tff:deint=all,trim=start_frame=2:end_frame=8,format=nv12",
        bffOutput: "format=yuv420p,setfield=tff,separatefields,select=eq(mod(n\\,4)\\,1)+eq(mod(n\\,4)\\,2),weave=first_field=bottom,yadif=mode=send_field:parity=bff:deint=all,trim=start_frame=2:end_frame=8,format=nv12"
    )
    private static let p010Graphs = GoldenManifest.FormatEntry.Graphs(
        tffInput: "setfield=tff,separatefields,select=eq(mod(n\\,4)\\,0)+eq(mod(n\\,4)\\,3),weave=first_field=top,format=p010le",
        bffInput: "setfield=tff,separatefields,select=eq(mod(n\\,4)\\,1)+eq(mod(n\\,4)\\,2),weave=first_field=bottom,format=p010le",
        tffOutput: "setfield=tff,separatefields,select=eq(mod(n\\,4)\\,0)+eq(mod(n\\,4)\\,3),weave=first_field=top,yadif=mode=send_field:parity=tff:deint=all,trim=start_frame=2:end_frame=8,format=p010le",
        bffOutput: "setfield=tff,separatefields,select=eq(mod(n\\,4)\\,1)+eq(mod(n\\,4)\\,2),weave=first_field=bottom,yadif=mode=send_field:parity=bff:deint=all,trim=start_frame=2:end_frame=8,format=p010le"
    )

    func testPublicContractsAreSendableAndFailureValuesAreExact() throws {
        assertSendable(YADIFJob.self)
        assertSendable(YADIFFailure.self)
        assertSendable(ProgressiveSurfacePool.self)

        let failures: [YADIFFailure] = [
            .invalidDimensions,
            .unsupportedPixelFormat(kCVPixelFormatType_32BGRA),
            .poolCreationFailed(-1),
            .poolAllocationFailed(-2),
            .nonIOSurfaceOutput,
            .invalidPlaneLayout,
            .metalTextureCacheCreationFailed(-3),
            .metalTextureMappingFailed(plane: 1, status: -4),
            .shaderLibraryUnavailable,
            .shaderFunctionUnavailable("missing"),
            .pipelineCreationFailed,
            .commandBufferAllocationFailed,
            .commandEncoderAllocationFailed,
            .commandFailed,
        ]
        XCTAssertEqual(failures, failures)
    }

    func testManifestMatchesLockSizesHashesAndGeneratorContract() throws {
        let root = repositoryRoot
        let manifestURL = root.appendingPathComponent(
            "Tests/Fixtures/Video/yadif-golden-manifest.json"
        )
        let manifest = try JSONDecoder().decode(
            GoldenManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let lock = try JSONDecoder().decode(
            FFmpegLock.self,
            from: Data(contentsOf: root.appendingPathComponent("Vendor/FFmpeg/ffmpeg.lock.json"))
        )

        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.ffmpegCommit, Self.lockedCommit)
        XCTAssertEqual(manifest.ffmpegCommit, lock.commit)
        XCTAssertEqual(manifest.width, Self.width)
        XCTAssertEqual(manifest.height, Self.height)
        XCTAssertEqual(manifest.generatorArguments.trim, "trim=start_frame=2:end_frame=8")
        XCTAssertEqual(Set(manifest.formats.keys), Set(["nv12", "p010le"]))
        XCTAssertEqual(manifest.formats["nv12"], .init(
            source: Self.nv12SourceRecipe,
            pixelFormat: "nv12",
            layout: "bi-planar-420-8-bit",
            inputFrameCount: 5,
            outputFrameCount: 6,
            bytesPerFrame: Self.nv12BytesPerFrame,
            graphs: Self.nv12Graphs
        ))
        XCTAssertEqual(manifest.formats["p010le"], .init(
            source: Self.p010SourceRecipe,
            pixelFormat: "p010le",
            layout: "bi-planar-420-10-bit-msb16",
            inputFrameCount: 5,
            outputFrameCount: 6,
            bytesPerFrame: Self.p010BytesPerFrame,
            graphs: Self.p010Graphs
        ))
        XCTAssertEqual(Set(manifest.files.keys), Set([
            "yadif-nv12-tff-input.bin",
            "yadif-nv12-bff-input.bin",
            "yadif-nv12-tff.bin",
            "yadif-nv12-bff.bin",
            "yadif-p010-tff-input.bin",
            "yadif-p010-bff-input.bin",
            "yadif-p010-tff.bin",
            "yadif-p010-bff.bin",
        ]))

        for (name, entry) in manifest.files {
            let bytesPerFrame = name.contains("p010")
                ? Self.p010BytesPerFrame : Self.nv12BytesPerFrame
            let expectedSize = bytesPerFrame * (name.contains("-input") ? 5 : 6)
            XCTAssertEqual(entry.byteCount, expectedSize, name)
            let bytes = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Video/\(name)"))
            XCTAssertEqual(bytes.count, expectedSize, name)
            XCTAssertEqual(SHA256.hash(data: bytes).hex, entry.sha256, name)
        }

        let interlacedInputs = try ["tff", "bff"].map { stem in
            try Data(contentsOf: root.appendingPathComponent(
                "Tests/Fixtures/Video/yadif-nv12-\(stem)-input.bin"
            ))
        }
        for (index, input) in interlacedInputs.enumerated() {
            let lumaHashes = (0..<5).map { frameIndex in
                let frameStart = frameIndex * Self.nv12BytesPerFrame
                return SHA256.hash(data: input.subdata(
                    in: frameStart..<(frameStart + Self.width * Self.height)
                )).hex
            }
            XCTAssertEqual(
                Set(lumaHashes).count,
                5,
                "\(index == 0 ? "tff" : "bff") must contain five unique luma frames"
            )
        }
        XCTAssertNotEqual(
            interlacedInputs[0],
            interlacedInputs[1],
            "TFF and BFF inputs must exercise different woven pictures"
        )

        let p010Inputs = try ["tff", "bff"].map { stem in
            try Data(contentsOf: root.appendingPathComponent(
                "Tests/Fixtures/Video/yadif-p010-\(stem)-input.bin"
            ))
        }
        for (index, input) in p010Inputs.enumerated() {
            assertP010LowBitsAreZero(
                input,
                label: "\(index == 0 ? "tff" : "bff") P010 input"
            )
            let lumaHashes = (0..<5).map { frameIndex in
                let frameStart = frameIndex * Self.p010BytesPerFrame
                return SHA256.hash(data: input.subdata(
                    in: frameStart..<(frameStart + Self.width * Self.height * 2)
                )).hex
            }
            XCTAssertEqual(
                Set(lumaHashes).count,
                5,
                "\(index == 0 ? "tff" : "bff") P010 must contain five unique luma frames"
            )
        }
        XCTAssertNotEqual(
            p010Inputs[0],
            p010Inputs[1],
            "P010 TFF and BFF inputs must exercise different woven pictures"
        )
    }

    func testScriptsPinNonGPLIgnoredHostOracleAndUseAtomicValidatedOutputs() throws {
        let build = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/build-yadif-reference.sh"),
            encoding: .utf8
        )
        let generate = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/generate-yadif-goldens.sh"),
            encoding: .utf8
        )
        let notices = try String(
            contentsOf: repositoryRoot.appendingPathComponent("THIRD_PARTY_NOTICES"),
            encoding: .utf8
        )
        for required in [
            "--disable-autodetect", "--disable-everything", "--disable-network",
            "--disable-gpl", "--disable-nonfree", "--disable-version3",
            "--disable-ffprobe", "--disable-ffplay",
            "--enable-decoder=wrapped_avframe",
            "--enable-filter=testsrc2,format,scale,setfield,separatefields,select,weave,yadif,trim",
        ] {
            XCTAssertTrue(build.contains(required), required)
        }
        XCTAssertTrue(build.contains("Vendor/FFmpeg/Work/yadif-reference"))
        XCTAssertTrue(build.contains("status --porcelain"))
        XCTAssertTrue(build.contains("CONFIG_GPL 0"))
        XCTAssertTrue(generate.contains("mktemp -d"))
        XCTAssertTrue(generate.contains(Self.nv12SourceRecipe))
        XCTAssertTrue(generate.contains(Self.p010SourceRecipe))
        XCTAssertFalse(generate.contains("testsrc2=size=64x36"))
        XCTAssertTrue(generate.contains("trim=start_frame=2:end_frame=8"))
        XCTAssertTrue(generate.contains("setfield=tff,separatefields"))
        XCTAssertTrue(generate.contains("eq(mod(n\\,4)\\,0)+eq(mod(n\\,4)\\,3)"))
        XCTAssertTrue(generate.contains("weave=first_field=top"))
        XCTAssertTrue(generate.contains("eq(mod(n\\,4)\\,1)+eq(mod(n\\,4)\\,2)"))
        XCTAssertTrue(generate.contains("weave=first_field=bottom"))
        XCTAssertTrue(generate.contains("progressive.bin"))
        XCTAssertTrue(generate.contains("cmp -s - <("))
        XCTAssertTrue(generate.contains("verify_unique_luma_frames nv12 tff 3456 2304"))
        XCTAssertTrue(generate.contains("verify_unique_luma_frames nv12 bff 3456 2304"))
        XCTAssertTrue(generate.contains("verify_unique_luma_frames p010 tff 6912 4608"))
        XCTAssertTrue(generate.contains("verify_unique_luma_frames p010 bff 6912 4608"))
        XCTAssertTrue(generate.contains("TFF and BFF inputs are unexpectedly identical"))
        XCTAssertTrue(generate.contains("17280"))
        XCTAssertTrue(generate.contains("20736"))
        XCTAssertTrue(generate.contains("34560"))
        XCTAssertTrue(generate.contains("41472"))
        XCTAssertTrue(generate.contains("verify_p010_low_bits"))
        XCTAssertTrue(generate.contains("format=p010le"))
        XCTAssertTrue(generate.contains("jq -n -S"))
        XCTAssertFalse(generate.contains("command -v ffmpeg"))
        XCTAssertFalse(build.contains("tinterlace"))
        XCTAssertFalse(generate.contains("tinterlace"))
        XCTAssertFalse(build.contains("--enable-gpl"))
        XCTAssertTrue(notices.contains("development/test-only YADIF oracle"))
        XCTAssertTrue(notices.contains("independent implementation"))
        XCTAssertTrue(notices.contains("does not copy FFmpeg source"))
    }

    func testPoolPreservesFormatSurfaceIdentityAndProgressiveAttachments() throws {
        for pixelFormat in [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        ] {
            let source = try makePixelBuffer(pixelFormat: pixelFormat)
            setRepresentativeAttachments(on: source)
            let pair = try ProgressiveSurfacePool().allocatePair(matching: source)

            XCTAssertFalse(pair.first === pair.second)
            for output in [pair.first, pair.second] {
                XCTAssertEqual(CVPixelBufferGetWidth(output), Self.width)
                XCTAssertEqual(CVPixelBufferGetHeight(output), Self.height)
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), pixelFormat)
                XCTAssertNotNil(CVPixelBufferGetIOSurface(output))
                XCTAssertEqual(CVPixelBufferGetPlaneCount(output), 2)
                XCTAssertEqual(attachmentNumber(output, kCVImageBufferFieldCountKey), 1)
                XCTAssertNil(attachment(output, kCVImageBufferFieldDetailKey))
                XCTAssertEqual(
                    attachmentString(output, kCVImageBufferColorPrimariesKey),
                    kCVImageBufferColorPrimaries_ITU_R_709_2 as String
                )
                XCTAssertEqual(
                    attachmentData(output, kCVImageBufferContentLightLevelInfoKey),
                    Data([0x00, 0x64, 0x00, 0x32])
                )
            }
        }
    }

    func testPoolRejectsUnsupportedDimensionsAndPlaneLayoutsWithTypedFailures() throws {
        let unsupported = try makePixelBuffer(pixelFormat: kCVPixelFormatType_32BGRA)
        XCTAssertThrowsError(try ProgressiveSurfacePool().allocatePair(matching: unsupported)) {
            XCTAssertEqual($0 as? YADIFFailure, .unsupportedPixelFormat(kCVPixelFormatType_32BGRA))
        }

        XCTAssertThrowsError(try YADIFSurfaceValidator.validate(.init(
            width: 63,
            height: 36,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            planeCount: 2,
            lumaWidth: 63,
            lumaHeight: 36,
            chromaWidth: 32,
            chromaHeight: 18
        ))) { XCTAssertEqual($0 as? YADIFFailure, .invalidDimensions) }

        XCTAssertThrowsError(try YADIFSurfaceValidator.validate(.init(
            width: 64,
            height: 36,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            planeCount: 1,
            lumaWidth: 64,
            lumaHeight: 36,
            chromaWidth: 0,
            chromaHeight: 0
        ))) { XCTAssertEqual($0 as? YADIFFailure, .invalidPlaneLayout) }
    }

    func testTextureAndKernelInitializationFailuresAreTyped() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        XCTAssertThrowsError(try YADIFTextureMapper(
            device: device,
            cacheFactory: { _ in (-31, nil) }
        )) { XCTAssertEqual($0 as? YADIFFailure, .metalTextureCacheCreationFailed(-31)) }

        let source = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let mapper = try YADIFTextureMapper(
            device: device,
            textureFactory: { _, _, _, _, _, _ in (-47, nil) }
        )
        XCTAssertThrowsError(try mapper.map(source)) {
            XCTAssertEqual($0 as? YADIFFailure, .metalTextureMappingFailed(plane: 0, status: -47))
        }

        XCTAssertThrowsError(try YADIFNV12Kernel(
            device: device,
            libraryFactory: { _, _ in nil }
        )) { XCTAssertEqual($0 as? YADIFFailure, .shaderLibraryUnavailable) }
        XCTAssertThrowsError(try YADIFNV12Kernel(
            device: device,
            functionName: "definitelyMissingYADIF"
        )) { XCTAssertEqual($0 as? YADIFFailure, .shaderFunctionUnavailable("definitelyMissingYADIF")) }
        XCTAssertThrowsError(try YADIFNV12Kernel(
            device: device,
            pipelineFactory: { _, _ in throw SyntheticFailure() }
        )) { XCTAssertEqual($0 as? YADIFFailure, .pipelineCreationFailed) }

        let output = try ProgressiveSurfacePool().allocatePair(matching: source)
        let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoderless = try YADIFNV12Kernel(
            device: device,
            encoderFactory: { _ in nil }
        )
        XCTAssertThrowsError(try encoderless.encode(
            YADIFJob(
                previous: normalized(source, id: 1),
                current: normalized(source, id: 2),
                next: normalized(source, id: 3),
                order: resolved(.top),
                spatialOnly: false
            ),
            outputs: output,
            into: commandBuffer
        )) { XCTAssertEqual($0 as? YADIFFailure, .commandEncoderAllocationFailed) }
    }

    func testNV12TFFMatchesPinnedOracleAndExactFieldRules() async throws {
        try await verifyGolden(order: .top, stem: "tff")
    }

    func testNV12BFFMatchesPinnedOracleAndExactFieldRules() async throws {
        try await verifyGolden(order: .bottom, stem: "bff")
    }

    func testP010TFFMatchesPinnedOracleAndExactStorageRules() async throws {
        try await verifyP010Golden(order: .top, stem: "tff")
    }

    func testP010BFFMatchesPinnedOracleAndExactStorageRules() async throws {
        try await verifyP010Golden(order: .bottom, stem: "bff")
    }

    func testMapperSelectsExactNV12AndP010PlaneFormatsForVideoAndFullRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        for (pixelFormat, expectedLuma, expectedChroma) in [
            (
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                MTLPixelFormat.r8Unorm,
                MTLPixelFormat.rg8Unorm
            ),
            (
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                MTLPixelFormat.r8Unorm,
                MTLPixelFormat.rg8Unorm
            ),
            (
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                MTLPixelFormat.r16Unorm,
                MTLPixelFormat.rg16Unorm
            ),
            (
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                MTLPixelFormat.r16Unorm,
                MTLPixelFormat.rg16Unorm
            ),
        ] {
            let mapped = try YADIFTextureMapper(device: device).map(
                try makePixelBuffer(pixelFormat: pixelFormat)
            )
            XCTAssertEqual(mapped.luma.pixelFormat, expectedLuma)
            XCTAssertEqual(mapped.chroma.pixelFormat, expectedChroma)
        }
    }

    func testEncodedResourceTokenRetainsTextureCacheOwnerUntilTokenRelease() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let source = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let outputs = try ProgressiveSurfacePool().allocatePair(matching: source)
        var mapper: YADIFTextureMapper? = try YADIFTextureMapper(device: device)
        weak let retainedMapper = mapper
        var kernel: YADIFNV12Kernel? = try YADIFNV12Kernel(
            device: device,
            textureMapper: try XCTUnwrap(mapper)
        )
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        var token: YADIFEncodedResources? = try XCTUnwrap(kernel).encode(
            YADIFJob(
                previous: normalized(source, id: 1),
                current: normalized(source, id: 2),
                next: normalized(source, id: 3),
                order: resolved(.top),
                spatialOnly: false
            ),
            outputs: outputs,
            into: commandBuffer
        )

        kernel = nil
        mapper = nil
        XCTAssertNotNil(
            retainedMapper,
            "the completion token must retain the texture-cache owner before submission"
        )

        let completed = expectation(description: "YADIF lifetime command completion")
        commandBuffer.addCompletedHandler { buffer in
            XCTAssertEqual(buffer.status, .completed)
            completed.fulfill()
        }
        commandBuffer.commit()
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertNotNil(
            retainedMapper,
            "the texture-cache owner must remain retained while the token is alive"
        )
        XCTAssertNotNil(token)

        token = nil
        XCTAssertNil(retainedMapper, "the texture-cache owner must deinit after token release")
    }

    func testProductionYADIFSourcesNeverLockDownloadCommitOrWaitAndCompileBothKernels() throws {
        let directory = repositoryRoot.appendingPathComponent(
            "Sources/VPlayerPlayback/Deinterlace/YADIF"
        )
        let lowLevelSwift = try ["YADIFTypes.swift", "ProgressiveSurfacePool.swift"].map {
            try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        let processor = try String(
            contentsOf: directory.appendingPathComponent("YADIFProcessor.swift"),
            encoding: .utf8
        )
        let swift = lowLevelSwift + "\n" + processor
        let metal = try String(
            contentsOf: directory.appendingPathComponent("YADIF.metal"),
            encoding: .utf8
        )
        for forbidden in [
            "CVPixelBufferLockBaseAddress", "CVPixelBufferGetBaseAddress", ".getBytes(",
            "waitUntilCompleted",
        ] {
            XCTAssertFalse(swift.contains(forbidden), forbidden)
        }
        XCTAssertFalse(lowLevelSwift.contains(".commit()"), "kernel encoder must not commit")
        XCTAssertEqual(processor.components(separatedBy: ".commit()").count - 1, 1)
        XCTAssertTrue(metal.contains("kernel void yadifPlane8"))
        XCTAssertTrue(metal.contains("kernel void yadifPlane16"))
        XCTAssertFalse(metal.lowercased().contains("placeholder"))
    }

    private func verifyGolden(order: FieldParity, stem: String) async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let inputBytes = try fixture("yadif-nv12-\(stem)-input.bin")
        let golden = try fixture("yadif-nv12-\(stem).bin")
        let inputs = try (0..<5).map { index in
            try makePixelBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                bytes: inputBytes.subdata(
                    in: index * Self.nv12BytesPerFrame..<(index + 1) * Self.nv12BytesPerFrame
                )
            )
        }
        let pool = ProgressiveSurfacePool()
        let kernel = try YADIFNV12Kernel(device: device)
        var rendered: [Data] = []

        for center in 1...3 {
            let outputs = try pool.allocatePair(matching: inputs[center])
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            let token = try kernel.encode(
                YADIFJob(
                    previous: normalized(inputs[center - 1], id: UInt64(center)),
                    current: normalized(inputs[center], id: UInt64(center + 1)),
                    next: normalized(inputs[center + 1], id: UInt64(center + 2)),
                    order: resolved(order),
                    spatialOnly: false
                ),
                outputs: outputs,
                into: commandBuffer
            )
            XCTAssertEqual(commandBuffer.status, .notEnqueued, "encoding must not commit")
            let completed = expectation(description: "YADIF GPU completion \(center)")
            commandBuffer.addCompletedHandler { buffer in
                withExtendedLifetime(token) {
                    XCTAssertEqual(buffer.status, .completed)
                    completed.fulfill()
                }
            }
            commandBuffer.commit()
            await fulfillment(of: [completed], timeout: 5)
            rendered.append(try packedBytes(outputs.first))
            rendered.append(try packedBytes(outputs.second))
        }

        XCTAssertEqual(rendered.count, 6)
        for index in rendered.indices {
            let expected = golden.subdata(
                in: index * Self.nv12BytesPerFrame..<(index + 1) * Self.nv12BytesPerFrame
            )
            assertPlane(
                rendered[index].prefix(Self.width * Self.height),
                expected.prefix(Self.width * Self.height),
                tolerance: 3,
                maximumOutlierFraction: 0.005,
                label: "\(stem) frame \(index) luma"
            )
            assertPlane(
                rendered[index].suffix(Self.width * Self.height / 2),
                expected.suffix(Self.width * Self.height / 2),
                tolerance: 4,
                maximumOutlierFraction: 0.005,
                label: "\(stem) frame \(index) chroma"
            )
            assertCopiedRows(
                output: rendered[index],
                current: inputBytes.subdata(
                    in: ((index / 2 + 1) * Self.nv12BytesPerFrame)..<((index / 2 + 2) * Self.nv12BytesPerFrame)
                ),
                copiedParity: copiedParity(order: order, outputIndex: index % 2),
                label: "\(stem) frame \(index)"
            )
            let chroma = rendered[index].suffix(Self.width * Self.height / 2)
            let cb = stride(from: 0, to: chroma.count, by: 2).map { chroma[chroma.index(chroma.startIndex, offsetBy: $0)] }
            let cr = stride(from: 1, to: chroma.count, by: 2).map { chroma[chroma.index(chroma.startIndex, offsetBy: $0)] }
            XCTAssertNotEqual(cb, cr, "Cb and Cr must be predicted independently")
        }
        for pair in 0..<3 {
            XCTAssertNotEqual(
                SHA256.hash(data: rendered[pair * 2].prefix(Self.width * Self.height)).hex,
                SHA256.hash(data: rendered[pair * 2 + 1].prefix(Self.width * Self.height)).hex,
                "field pair \(pair) must contain two different pictures"
            )
        }
    }

    private func verifyP010Golden(order: FieldParity, stem: String) async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let inputBytes = try fixture("yadif-p010-\(stem)-input.bin")
        let golden = try fixture("yadif-p010-\(stem).bin")
        XCTAssertEqual(inputBytes.count, 5 * Self.p010BytesPerFrame)
        XCTAssertEqual(golden.count, 6 * Self.p010BytesPerFrame)
        assertP010LowBitsAreZero(inputBytes, label: "\(stem) input")
        assertP010LowBitsAreZero(golden, label: "\(stem) oracle")
        let inputs = try (0..<5).map { index in
            try makePixelBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                bytes: inputBytes.subdata(
                    in: index * Self.p010BytesPerFrame..<(index + 1) * Self.p010BytesPerFrame
                )
            )
        }
        let pool = ProgressiveSurfacePool()
        let kernel = try YADIFNV12Kernel(device: device)
        var rendered: [Data] = []

        for center in 1...3 {
            let outputs = try pool.allocatePair(matching: inputs[center])
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            let token = try kernel.encode(
                YADIFJob(
                    previous: normalized(inputs[center - 1], id: UInt64(center)),
                    current: normalized(inputs[center], id: UInt64(center + 1)),
                    next: normalized(inputs[center + 1], id: UInt64(center + 2)),
                    order: resolved(order),
                    spatialOnly: false
                ),
                outputs: outputs,
                into: commandBuffer
            )
            XCTAssertEqual(commandBuffer.status, .notEnqueued, "encoding must not commit")
            let completed = expectation(description: "P010 YADIF GPU completion \(center)")
            commandBuffer.addCompletedHandler { buffer in
                withExtendedLifetime(token) {
                    XCTAssertEqual(buffer.status, .completed)
                    completed.fulfill()
                }
            }
            commandBuffer.commit()
            await fulfillment(of: [completed], timeout: 5)
            rendered.append(try packedBytes(outputs.first))
            rendered.append(try packedBytes(outputs.second))
        }

        XCTAssertEqual(rendered.count, 6)
        let lumaSampleCount = Self.width * Self.height
        for index in rendered.indices {
            let expected = golden.subdata(
                in: index * Self.p010BytesPerFrame..<(index + 1) * Self.p010BytesPerFrame
            )
            assertP010LowBitsAreZero(rendered[index], label: "\(stem) frame \(index)")
            let actualCodes = p010CodeUnits(rendered[index])
            let expectedCodes = p010CodeUnits(expected)
            assertCodePlane(
                actualCodes.prefix(lumaSampleCount),
                expectedCodes.prefix(lumaSampleCount),
                tolerance: 12,
                maximumOutlierFraction: 0.005,
                label: "\(stem) P010 frame \(index) luma"
            )
            assertCodePlane(
                actualCodes.suffix(Self.width * Self.height / 2),
                expectedCodes.suffix(Self.width * Self.height / 2),
                tolerance: 16,
                maximumOutlierFraction: 0.005,
                label: "\(stem) P010 frame \(index) chroma"
            )
            assertCopiedRows(
                output: rendered[index],
                current: inputBytes.subdata(
                    in: ((index / 2 + 1) * Self.p010BytesPerFrame)..<((index / 2 + 2) * Self.p010BytesPerFrame)
                ),
                copiedParity: copiedParity(order: order, outputIndex: index % 2),
                bytesPerStoredComponent: 2,
                label: "\(stem) P010 frame \(index)"
            )
            let chroma = Array(actualCodes.suffix(Self.width * Self.height / 2))
            let cb = stride(from: 0, to: chroma.count, by: 2).map { chroma[$0] }
            let cr = stride(from: 1, to: chroma.count, by: 2).map { chroma[$0] }
            XCTAssertNotEqual(cb, cr, "P010 Cb and Cr must be predicted independently")
        }
        for pair in 0..<3 {
            let firstLuma = rendered[pair * 2].prefix(Self.width * Self.height * 2)
            let secondLuma = rendered[pair * 2 + 1].prefix(Self.width * Self.height * 2)
            XCTAssertNotEqual(
                SHA256.hash(data: firstLuma).hex,
                SHA256.hash(data: secondLuma).hex,
                "P010 field pair \(pair) must contain two different pictures"
            )
        }
    }

    private func assertCodePlane(
        _ actual: ArraySlice<UInt16>,
        _ expected: ArraySlice<UInt16>,
        tolerance: Int,
        maximumOutlierFraction: Double,
        label: String
    ) {
        XCTAssertEqual(actual.count, expected.count, label)
        let outliers = zip(actual, expected).reduce(into: 0) { count, pair in
            if abs(Int(pair.0) - Int(pair.1)) > tolerance { count += 1 }
        }
        XCTAssertLessThanOrEqual(
            Double(outliers) / Double(max(1, actual.count)),
            maximumOutlierFraction,
            "\(label): \(outliers) outliers"
        )
    }

    private func assertP010LowBitsAreZero(_ data: Data, label: String) {
        let nonzero = p010StoredUnits(data).filter { $0 & 0x003f != 0 }
        XCTAssertTrue(nonzero.isEmpty, "\(label): \(nonzero.count) low-six-bit violations")
    }

    private func p010CodeUnits(_ data: Data) -> [UInt16] {
        p010StoredUnits(data).map { $0 >> 6 }
    }

    private func p010StoredUnits(_ data: Data) -> [UInt16] {
        XCTAssertTrue(data.count.isMultiple(of: 2))
        return stride(from: 0, to: data.count, by: 2).map { index in
            UInt16(data[index]) | UInt16(data[index + 1]) << 8
        }
    }

    private func assertPlane(
        _ actual: Data.SubSequence,
        _ expected: Data.SubSequence,
        tolerance: Int,
        maximumOutlierFraction: Double,
        label: String
    ) {
        XCTAssertEqual(actual.count, expected.count, label)
        let outliers = zip(actual, expected).reduce(into: 0) { count, pair in
            if abs(Int(pair.0) - Int(pair.1)) > tolerance { count += 1 }
        }
        XCTAssertLessThanOrEqual(
            Double(outliers) / Double(max(1, actual.count)),
            maximumOutlierFraction,
            "\(label): \(outliers) outliers"
        )
    }

    private func assertCopiedRows(
        output: Data,
        current: Data,
        copiedParity: Int,
        bytesPerStoredComponent: Int = 1,
        label: String
    ) {
        for plane in 0..<2 {
            let width = Self.width * bytesPerStoredComponent
            let height = plane == 0 ? Self.height : Self.height / 2
            let offset = plane == 0
                ? 0 : Self.width * Self.height * bytesPerStoredComponent
            for y in stride(from: copiedParity, to: height, by: 2) {
                let range = offset + y * width..<offset + (y + 1) * width
                XCTAssertEqual(output.subdata(in: range), current.subdata(in: range), "\(label) plane \(plane) row \(y)")
            }
        }
    }

    private func copiedParity(order: FieldParity, outputIndex: Int) -> Int {
        let first = order == .top ? 0 : 1
        return outputIndex == 0 ? first : 1 - first
    }

    private func normalized(_ pixelBuffer: CVPixelBuffer, id: UInt64) -> NormalizedDecodedFrame {
        let generation = MediaGeneration(rawValue: 1)
        let duration = CMTime(value: 1, timescale: 25)
        let tenBit = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        ].contains(CVPixelBufferGetPixelFormatType(pixelBuffer))
        return NormalizedDecodedFrame(
            frame: DecodedVideoFrame(
                accessUnitID: id,
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: Int64(id), timescale: 25),
                duration: duration,
                generation: generation,
                parserMetadata: .init(
                    fieldOrder: nil,
                    pictureStructure: .frame,
                    isInterlaced: true,
                    repeatFirstField: false,
                    topFieldFirst: nil,
                    sourcePTS90k: nil
                ),
                formatMetadata: VideoFormatMetadata(
                    dimensions: .init(width: 64, height: 36),
                    bitDepth: tenBit ? 10 : 8,
                    range: .video,
                    matrix: .bt709,
                    transfer: .bt709,
                    primaries: .bt709,
                    cleanAperture: nil,
                    chromaLocation: .init(topField: nil, bottomField: nil),
                    hdrStaticMetadata: .init(
                        masteringDisplayColorVolume: nil,
                        contentLightLevelInfo: nil
                    )
                )
            ),
            presentationTimeStamp: CMTime(value: Int64(id), timescale: 25),
            frameDuration: duration,
            fieldDuration: CMTime(value: 1, timescale: 50),
            timingWasSynthesized: false,
            provenance: .trustedPresentationCadence
        )
    }

    private func resolved(_ parity: FieldParity) -> ResolvedFieldOrder {
        .init(parity: parity, confidence: .signaled, source: .parser)
    }

    private func makePixelBuffer(
        pixelFormat: OSType,
        bytes: Data? = nil
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            nil, Self.width, Self.height, pixelFormat,
            attributes as CFDictionary, &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let result = try XCTUnwrap(pixelBuffer)
        if let bytes { try writePacked(bytes, to: result) }
        return result
    }

    private func writePacked(_ data: Data, to pixelBuffer: CVPixelBuffer) throws {
        let bytesPerComponent = bytesPerStoredComponent(in: pixelBuffer)
        let expectedByteCount = Self.nv12BytesPerFrame * bytesPerComponent
        XCTAssertEqual(data.count, expectedByteCount)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        try data.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { throw SyntheticFailure() }
            var offset = 0
            for plane in 0..<2 {
                let componentCount = plane == 0 ? 1 : 2
                let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                    * componentCount * bytesPerComponent
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let destination = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane))
                for y in 0..<height {
                    memcpy(destination.advanced(by: y * stride), source.advanced(by: offset + y * width), width)
                }
                offset += width * height
            }
        }
    }

    private func packedBytes(_ pixelBuffer: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let bytesPerComponent = bytesPerStoredComponent(in: pixelBuffer)
        var result = Data()
        result.reserveCapacity(Self.nv12BytesPerFrame * bytesPerComponent)
        for plane in 0..<2 {
            let componentCount = plane == 0 ? 1 : 2
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * componentCount * bytesPerComponent
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let source = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane))
            for y in 0..<height {
                result.append(source.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width)
            }
        }
        return result
    }

    private func bytesPerStoredComponent(in pixelBuffer: CVPixelBuffer) -> Int {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return 2
        default:
            return 1
        }
    }

    private func setRepresentativeAttachments(on pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferContentLightLevelInfoKey,
            Data([0x00, 0x64, 0x00, 0x32]) as CFData, .shouldPropagate
        )
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferFieldCountKey, 2 as CFNumber, .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferFieldDetailKey,
            kCVImageBufferFieldDetailTemporalTopFirst, .shouldPropagate
        )
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> CFTypeRef? {
        CVBufferCopyAttachment(buffer, key, nil)
    }

    private func attachmentNumber(_ buffer: CVPixelBuffer, _ key: CFString) -> Int? {
        (attachment(buffer, key) as? NSNumber)?.intValue
    }

    private func attachmentString(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        attachment(buffer, key) as? String
    }

    private func attachmentData(_ buffer: CVPixelBuffer, _ key: CFString) -> Data? {
        attachment(buffer, key) as? Data
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: repositoryRoot.appendingPathComponent("Tests/Fixtures/Video/\(name)"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}

private struct GoldenManifest: Decodable {
    struct Arguments: Decodable {
        let trim: String
    }
    struct FormatEntry: Decodable, Equatable {
        struct Graphs: Decodable, Equatable {
            let tffInput: String
            let bffInput: String
            let tffOutput: String
            let bffOutput: String
        }

        let source: String
        let pixelFormat: String
        let layout: String
        let inputFrameCount: Int
        let outputFrameCount: Int
        let bytesPerFrame: Int
        let graphs: Graphs
    }
    struct FileEntry: Decodable {
        let byteCount: Int
        let sha256: String
    }
    let schemaVersion: Int
    let ffmpegCommit: String
    let width: Int
    let height: Int
    let formats: [String: FormatEntry]
    let generatorArguments: Arguments
    let files: [String: FileEntry]
}

private struct FFmpegLock: Decodable { let commit: String }
private struct SyntheticFailure: Error {}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
