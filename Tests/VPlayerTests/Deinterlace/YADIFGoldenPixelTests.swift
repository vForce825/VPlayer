// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Metal
import XCTest
#if os(iOS)
import Darwin
#endif
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

    #if os(iOS)
    #if !DEBUG
    func testCPUYADIFBenchmarkReportsNativeHostMeasurementsWithoutDeviceQualification() throws {
        for (width, height) in [(1_920, 1_080), (3_840, 2_160)] {
            for depth in [8, 10] {
                let context = "width=\(width) height=\(height) depth=\(depth)"
                emitCPUBenchmark("IOS_CPU_YADIF_PHASE \(context) phase=setup_begin")
                let setupStart = ContinuousClock.now
                let format = depth == 8 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                let inputs = try (0..<3).map { seed in
                    var buffer: CVPixelBuffer?
                    let status = CVPixelBufferCreate(nil, width, height, format,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
                    XCTAssertEqual(status, kCVReturnSuccess)
                    let pixel = try XCTUnwrap(buffer)
                    XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
                    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
                    for plane in 0..<2 {
                        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, plane))
                        let rows = CVPixelBufferGetHeightOfPlane(pixel, plane)
                        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
                        fillCPUBenchmarkPlane(base, width: width, rows: rows,
                            stride: stride, depth: depth, seed: seed)
                    }
                    return pixel
                }
                let setupMilliseconds = cpuBenchmarkMilliseconds(since: setupStart)
                emitCPUBenchmark("IOS_CPU_YADIF_PHASE \(context) phase=setup_end setup_ms=\(setupMilliseconds)")
                emitCPUBenchmark("IOS_CPU_YADIF_PHASE \(context) phase=output_begin")
                let outputStart = ContinuousClock.now
                let outputs = try ProgressiveSurfacePool().allocatePair(matching: inputs[1])
                let job = YADIFJob(previous: normalized(inputs[0], id: 1),
                    current: normalized(inputs[1], id: 2), next: normalized(inputs[2], id: 3),
                    order: resolved(.top), spatialOnly: false)
                let outputMilliseconds = cpuBenchmarkMilliseconds(since: outputStart)
                emitCPUBenchmark("IOS_CPU_YADIF_PHASE \(context) phase=output_end output_ms=\(outputMilliseconds)")
                emitCPUBenchmark("IOS_CPU_YADIF_PHASE \(context) phase=warmup_begin")
                let warmupStart = ContinuousClock.now
                try CPUVideoProcessing.yadif(job: job, outputs: outputs)
                let warmupMilliseconds = cpuBenchmarkMilliseconds(since: warmupStart)
                emitCPUBenchmark("IOS_CPU_YADIF_PHASE \(context) phase=warmup_end warmup_ms=\(warmupMilliseconds)")
                var milliseconds: [Double] = []
                for sample in 0..<5 {
                    emitCPUBenchmark("IOS_CPU_YADIF_PHASE \(context) phase=sample_begin sample=\(sample)")
                    let start = ContinuousClock.now
                    try CPUVideoProcessing.yadif(job: job, outputs: outputs)
                    let elapsed = cpuBenchmarkMilliseconds(since: start)
                    milliseconds.append(elapsed)
                    emitCPUBenchmark("IOS_CPU_YADIF_PHASE \(context) phase=sample_end sample=\(sample) pair_ms=\(elapsed)")
                }
                #if targetEnvironment(simulator)
                let environment = "simulator-not-iphone-hardware"
                #else
                let environment = "device-short-run-not-thermal-qualification"
                #endif
                emitCPUBenchmark("IOS_CPU_YADIF_BENCH \(context) workers=\(min(4, ProcessInfo.processInfo.activeProcessorCount)) setup_ms=\(setupMilliseconds) output_ms=\(outputMilliseconds) warmup_ms=\(warmupMilliseconds) pair_ms=\(milliseconds) environment=\(environment) configuration=release")
            }
        }
    }

    private func cpuBenchmarkMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    private func emitCPUBenchmark(_ message: String) {
        // Write directly to the descriptor so a watchdog termination cannot
        // strand the last phase in a buffered print/stdio stream.
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    #endif

    func testCPUBenchmarkPeriodicFillMatchesOriginalFormulaAndPreservesPadding() throws {
        for depth in [8, 10] {
            let bytesPerComponent = depth == 8 ? 1 : 2
            // Cross both sample periods and row-phase wraps. Odd strides also
            // prove that P010 bulk copies never require an aligned row address.
            for (width, rows) in [(1, 1), (7, 3), (257, 5), (1_025, 3), (7, 1_025)] {
                for padding in [0, 1, 13] {
                    let stride = width * bytesPerComponent + padding
                    for seed in 0..<3 {
                        let guardBytes = 16
                        var actual = [UInt8](repeating: 0xA5,
                            count: guardBytes + stride * rows + guardBytes)
                        var expected = actual
                        try actual.withUnsafeMutableBytes { storage in
                            let base = try XCTUnwrap(storage.baseAddress).advanced(by: guardBytes)
                            fillCPUBenchmarkPlane(base, width: width, rows: rows,
                                stride: stride, depth: depth, seed: seed)
                        }
                        try expected.withUnsafeMutableBytes { storage in
                            let base = try XCTUnwrap(storage.baseAddress).advanced(by: guardBytes)
                            for y in 0..<rows {
                                let row = base.advanced(by: y * stride)
                                for x in 0..<width {
                                    if depth == 8 {
                                        row.storeBytes(of: UInt8(truncatingIfNeeded: x * 13 + y * 17 + seed * 31),
                                            toByteOffset: x, as: UInt8.self)
                                    } else {
                                        let code = UInt16((x * 13 + y * 17 + seed * 31) & 1_023) << 6
                                        withUnsafeBytes(of: code) { sample in
                                            row.advanced(by: x * 2).copyMemory(
                                                from: sample.baseAddress!, byteCount: 2)
                                        }
                                    }
                                }
                            }
                        }
                        XCTAssertEqual(actual, expected,
                            "depth=\(depth) width=\(width) rows=\(rows) padding=\(padding) seed=\(seed)")
                    }
                }
            }
        }
    }

    private func fillCPUBenchmarkPlane(
        _ base: UnsafeMutableRawPointer, width: Int, rows: Int,
        stride: Int, depth: Int, seed: Int
    ) {
        precondition(depth == 8 || depth == 10)
        let bytesPerComponent = depth == 8 ? 1 : 2
        precondition(width > 0 && rows > 0 && stride >= width * bytesPerComponent)
        precondition((0..<3).contains(seed))
        let period = depth == 8 ? 256 : 1_024
        let inverse = depth == 8 ? 197 : 709
        // 13 * inverse == 1 (mod period). Rotating the x-only template by
        // (17*y + 31*seed)*inverse gives exactly the original scalar formula.
        // The doubled template makes every rotated period contiguous.
        func copyTemplate(_ template: UnsafeRawBufferPointer) {
            guard let source = template.baseAddress else { preconditionFailure("Empty CPU fixture template") }
            for y in 0..<rows {
                let offset = ((y * 17 + seed * 31) * inverse) & (period - 1)
                let origin = source.advanced(by: offset * bytesPerComponent)
                let row = base.advanced(by: y * stride)
                var x = 0
                while x < width {
                    let count = min(period, width - x)
                    row.advanced(by: x * bytesPerComponent).copyMemory(
                        from: origin, byteCount: count * bytesPerComponent)
                    x += count
                }
            }
        }
        if depth == 8 {
            let template = (0..<(period * 2)).map { UInt8(truncatingIfNeeded: $0 * 13) }
            template.withUnsafeBytes(copyTemplate)
        } else {
            let template = (0..<(period * 2)).map { UInt16(($0 * 13) & 1_023) << 6 }
            template.withUnsafeBytes(copyTemplate)
        }
    }

    // These tests call the same compiled C translation unit as the adapter. A
    // required-NEON request must execute vector blocks; scalar fallback cannot
    // accidentally turn an arm64 SIMD regression into a passing parity test.
    func testCPUNativeBackendsMatchEveryPinnedNV12AndP010FieldExactly() throws {
        try requireNativeNEON()
        for (depth, name, bytesPerFrame) in [
            (8, "nv12", Self.nv12BytesPerFrame),
            (10, "p010", Self.p010BytesPerFrame),
        ] {
            let bytesPerSample = depth == 8 ? 1 : 2
            for (topFieldFirst, stem) in [(true, "tff"), (false, "bff")] {
                let input = try fixture("yadif-\(name)-\(stem)-input.bin")
                let golden = try fixture("yadif-\(name)-\(stem).bin")
                for backend in [NativeBackend.scalar, .neon] {
                    var actual = Data()
                    for center in 1...3 {
                        for field in 0..<2 {
                            for componentCount in [1, 2] {
                                let width = componentCount == 1 ? Self.width : Self.width / 2
                                let height = componentCount == 1 ? Self.height : Self.height / 2
                                let planeOffset = componentCount == 1 ? 0 : Self.width * Self.height * bytesPerSample
                                let inputs = try ((center - 1)...(center + 1)).map { frame in
                                    let plane = try NativePlane(width: width, height: height,
                                        components: componentCount, depth: depth, padding: 7, offset: 1)
                                    plane.copyPacked(input.subdata(in: (frame * bytesPerFrame + planeOffset)..<(frame * bytesPerFrame + planeOffset + plane.rowBytes * height)))
                                    return plane
                                }
                                let output = try NativePlane(width: width, height: height,
                                    components: componentCount, depth: depth, padding: 9, offset: 3)
                                let result = runNativePlane(inputs, output: output, backend: backend,
                                    outputIndex: field, topFieldFirst: topFieldFirst, spatialOnly: false)
                                XCTAssertEqual(result.status, 0, "\(name) \(stem) \(backend)")
                                if backend == .neon { XCTAssertGreaterThan(result.blocks, 0) }
                                output.assertUnwrittenBytes(firstRow: 0, rowCount: height)
                                actual.append(output.packedBytes())
                            }
                        }
                    }
                    XCTAssertEqual(actual, golden, "\(name) \(stem) \(backend) pinned FFmpeg oracle")
                }
            }
        }
    }

    func testCPUNEONMatchesScalarAcrossStridesParitiesAndPatterns() throws {
        try requireNativeNEON()
        for depth in [8, 10] {
            for components in [1, 2] {
                for width in [7, 10, 13, 14, 17, 31, 64] {
                    for height in [2, 3, 6, 9] {
                        for (patternIndex, pattern) in NativePattern.allCases.enumerated() {
                            let padding = [0, 1, 13][patternIndex % 3]
                            let inputs = try (0..<3).map { frame in
                                let plane = try NativePlane(width: width, height: height,
                                    components: components, depth: depth, padding: padding + frame,
                                    offset: frame + 1)
                                plane.fill(pattern: pattern, frame: frame, seed: 0x59AD_1F00)
                                return plane
                            }
                            let snapshots = inputs.map { $0.snapshot() }
                            for field in 0..<2 {
                                for topFieldFirst in [false, true] {
                                    for spatialOnly in [false, true] {
                                        try assertNativeParity(inputs, outputIndex: field,
                                            topFieldFirst: topFieldFirst, spatialOnly: spatialOnly,
                                            padding: padding, offset: 1,
                                            label: "\(pattern.rawValue) depth=\(depth) components=\(components) width=\(width) height=\(height) field=\(field) tff=\(topFieldFirst) spatial=\(spatialOnly)")
                                    }
                                }
                            }
                            for (plane, before) in zip(inputs, snapshots) {
                                XCTAssertEqual(plane.snapshot(), before, "Input planes are read-only")
                            }
                        }
                    }
                }
            }
        }
    }

    func testCPUNEONPreservesStrictTiesAndNearGatedFarCandidatesInEveryLane() throws {
        try requireNativeNEON()
        let cases = [
            (above: [1, 3, 2, 2, 1, 1, 2], below: [0, 0, 3, 0, 2, 2, 4], expected: 1, name: "strict-tie"),
            (above: [3, 2, 3, 4, 3, 1, 1], below: [2, 1, 0, 4, 4, 0, 2], expected: 4, name: "near-gated-far"),
        ]
        for depth in [8, 10] {
            for components in [1, 2] {
                for lane in 0..<8 {
                    for vector in cases {
                        let inputs = try (0..<3).map { frame in
                            let plane = try NativePlane(width: 14, height: 6,
                                components: components, depth: depth, padding: 3, offset: 1)
                            plane.fill(pattern: .gradient, frame: frame, seed: 0x825)
                            return plane
                        }
                        let sample = 3 * components + lane
                        for tap in 0..<7 {
                            let index = sample + (tap - 3) * components
                            inputs[1].setCode(vector.above[tap], sample: index, row: 1, lowBits: 0x3F)
                            inputs[1].setCode(vector.below[tap], sample: index, row: 3, lowBits: 0x15)
                        }
                        for backend in [NativeBackend.scalar, .neon] {
                            let output = try NativePlane(like: inputs[1], padding: 3, offset: 1)
                            let result = runNativePlane(inputs, output: output, backend: backend,
                                outputIndex: 0, topFieldFirst: false, spatialOnly: true,
                                firstRow: 2, rowCount: 1)
                            XCTAssertEqual(result.status, 0)
                            if backend == .neon { XCTAssertGreaterThan(result.blocks, 0) }
                            XCTAssertEqual(output.code(sample: sample, row: 2), vector.expected,
                                "\(vector.name) depth=\(depth) components=\(components) lane=\(lane) backend=\(backend)")
                            output.assertUnwrittenBytes(firstRow: 2, rowCount: 1)
                        }
                    }
                }
            }
        }
    }

    func testCPUNEONMatchesScalarForInputAliasesAndRandomRowPartitions() throws {
        try requireNativeNEON()
        var random = NativeRandom(state: 0xE19A_D1F0_8250_0011)
        // Include every input alias relationship; output always remains separate.
        let aliases = [[0, 1, 2], [0, 0, 2], [0, 1, 0], [0, 1, 1], [1, 1, 1]]
        for iteration in 0..<120 {
            let depth = iteration.isMultiple(of: 2) ? 8 : 10
            let components = (iteration / 2).isMultiple(of: 2) ? 1 : 2
            let width = 14 + Int(random.next() % 67)
            let height = 2 + Int(random.next() % 15)
            let padding = Int(random.next() % 17)
            let inputPlanes = try (0..<3).map { frame in
                let plane = try NativePlane(width: width, height: height,
                    components: components, depth: depth, padding: padding, offset: frame + 1)
                plane.fill(pattern: NativePattern.allCases[iteration % NativePattern.allCases.count],
                    frame: frame, seed: random.next())
                return plane
            }
            let inputs = aliases[iteration % aliases.count].map { inputPlanes[$0] }
            let before = inputPlanes.map { $0.snapshot() }
            let field = iteration % 2
            let tff = (iteration / 2).isMultiple(of: 2)
            let spatial = (iteration / 4).isMultiple(of: 2)
            let scalar = try NativePlane(like: inputs[1], padding: padding + 3, offset: 3)
            let partitioned = try NativePlane(like: inputs[1], padding: padding + 3, offset: 3)
            XCTAssertEqual(runNativePlane(inputs, output: scalar, backend: .scalar,
                outputIndex: field, topFieldFirst: tff, spatialOnly: spatial).status, 0)
            let copiedParity = field == 0 ? (tff ? 0 : 1) : (tff ? 1 : 0)
            var ranges: [Range<Int>] = []
            var row = 0
            while row < height {
                let count = min(1 + Int(random.next() % 4), height - row)
                ranges.append(row..<(row + count))
                row += count
            }
            // Execute partitions out of order to catch accidental dependence on
            // output row history while retaining the adapter's row-range API.
            var totalBlocks = 0
            for range in ranges.reversed() {
                let hasSynthesis = range.contains { ($0 & 1) != copiedParity }
                let snapshot = partitioned.snapshot()
                let result = runNativePlane(inputs, output: partitioned, backend: .neon,
                    outputIndex: field, topFieldFirst: tff, spatialOnly: spatial,
                    firstRow: range.lowerBound, rowCount: range.count)
                if hasSynthesis {
                    XCTAssertEqual(result.status, 0, "partition \(range)")
                    XCTAssertGreaterThan(result.blocks, 0)
                    totalBlocks += result.blocks
                } else {
                    XCTAssertEqual(result.status, -2)
                    XCTAssertEqual(result.blocks, 0)
                    XCTAssertEqual(partitioned.snapshot(), snapshot, "Rejected copy-only range must not write")
                    XCTAssertEqual(runNativePlane(inputs, output: partitioned, backend: .automatic,
                        outputIndex: field, topFieldFirst: tff, spatialOnly: spatial,
                        firstRow: range.lowerBound, rowCount: range.count).status, 0)
                }
                partitioned.assertUnchangedOutsideRows(snapshot, rows: range)
            }
            XCTAssertGreaterThan(totalBlocks, 0)
            XCTAssertEqual(partitioned.snapshot(), scalar.snapshot(), "random case \(iteration), aliases=\(aliases[iteration % aliases.count])")
            partitioned.assertUnwrittenBytes(firstRow: 0, rowCount: height)
            for (plane, snapshot) in zip(inputPlanes, before) {
                XCTAssertEqual(plane.snapshot(), snapshot)
            }
        }
    }

    func testCPURequiredNEONRejectsNoVectorWorkAndOutputOverlapWithoutWrites() throws {
        #if arch(arm64)
        XCTAssertEqual(VPYADIFNEONAvailable(), 1, "The arm64 build must compile the NEON backend")
        #endif
        for depth in [8, 10] {
            for components in [1, 2] {
                for width in [1, 2, 3, 6, 7, 9] where (width - 6) * components < 8 {
                    let inputs = try (0..<3).map { frame in
                        let plane = try NativePlane(width: width, height: 7,
                            components: components, depth: depth, padding: frame, offset: 1)
                        plane.fill(pattern: .random, frame: frame, seed: 0x825)
                        return plane
                    }
                    try assertNativeParity(inputs, outputIndex: 1, topFieldFirst: false,
                        spatialOnly: false, padding: 3, offset: 1, label: "narrow width=\(width)")
                }
                let inputs = try (0..<3).map { frame in
                    let plane = try NativePlane(width: 32, height: 8,
                        components: components, depth: depth, padding: 9, offset: 3)
                    plane.fill(pattern: .random, frame: frame, seed: 0xD15A_1101)
                    return plane
                }
                for aliasIndex in 0..<3 {
                    let before = inputs[aliasIndex].snapshot()
                    for displacement in [0, 1] {
                        let result = runNativePlane(inputs, output: inputs[aliasIndex], backend: .neon,
                            outputIndex: 0, topFieldFirst: true, spatialOnly: false,
                            outputByteOffset: displacement)
                        XCTAssertEqual(result.status, -2)
                        XCTAssertEqual(result.blocks, 0)
                        XCTAssertEqual(inputs[aliasIndex].snapshot(), before, "Overlapping required NEON must not write")
                    }
                }
                let output = try NativePlane(like: inputs[1], padding: 5, offset: 1)
                for (firstRow, count) in [(0, 0), (8, 0), (0, 1), (2, 1)] {
                    let before = output.snapshot()
                    let result = runNativePlane(inputs, output: output, backend: .neon,
                        outputIndex: 0, topFieldFirst: true, spatialOnly: false,
                        firstRow: firstRow, rowCount: count)
                    XCTAssertEqual(result.status, -2)
                    XCTAssertEqual(result.blocks, 0)
                    XCTAssertEqual(output.snapshot(), before)
                }
            }
        }
        if VPYADIFNEONAvailable() == 0 {
            let inputs = try (0..<3).map { _ in
                try NativePlane(width: 32, height: 6, components: 1, depth: 8)
            }
            let output = try NativePlane(like: inputs[1])
            let before = output.snapshot()
            let result = runNativePlane(inputs, output: output, backend: .neon,
                outputIndex: 0, topFieldFirst: true, spatialOnly: false)
            XCTAssertEqual(result.status, -2)
            XCTAssertEqual(result.blocks, 0)
            XCTAssertEqual(output.snapshot(), before)
        }
    }

    func testCPUNEONGuardPagesPreserveBounds() throws {
        try requireNativeNEON()
        var random = NativeRandom(state: 0xB0AD_5AFE_8250_0001)
        for iteration in 0..<64 {
            let depth = iteration.isMultiple(of: 2) ? 8 : 10
            let components = (iteration / 2).isMultiple(of: 2) ? 1 : 2
            let width = 14 + Int(random.next() % 35)
            let height = 2 + Int(random.next() % 9)
            let edge: NativeGuardEdge = (iteration / 4).isMultiple(of: 2) ? .leading : .trailing
            let padding = iteration % 3
            let inputs = try (0..<3).map { frame in
                let plane = try NativePlane(width: width, height: height,
                    components: components, depth: depth, padding: padding, guardEdge: edge)
                plane.fill(pattern: .random, frame: frame, seed: random.next())
                return plane
            }
            let before = inputs.map { $0.snapshot() }
            let output = try NativePlane(like: inputs[1], padding: padding, guardEdge: edge)
            let scalar = try NativePlane(like: inputs[1], padding: padding, guardEdge: edge)
            let field = iteration % 2
            let tff = (iteration / 2).isMultiple(of: 2)
            let spatial = (iteration / 8).isMultiple(of: 2)
            let reference = runNativePlane(inputs, output: scalar, backend: .scalar,
                outputIndex: field, topFieldFirst: tff, spatialOnly: spatial)
            let candidate = runNativePlane(inputs, output: output, backend: .neon,
                outputIndex: field, topFieldFirst: tff, spatialOnly: spatial)
            XCTAssertEqual(reference.status, 0)
            XCTAssertEqual(candidate.status, 0)
            XCTAssertGreaterThan(candidate.blocks, 0)
            XCTAssertEqual(output.snapshot(), scalar.snapshot(), "guard-page case \(iteration)")
            output.assertUnwrittenBytes(firstRow: 0, rowCount: height)
            for (plane, snapshot) in zip(inputs, before) { XCTAssertEqual(plane.snapshot(), snapshot) }
        }
    }

    #if !DEBUG
    func testCPUYADIFScalarVersusNEONBenchmarkReportsPairedPatternMeasurements() throws {
        try requireNativeNEON()
        let width = 1_920
        let height = 1_080
        let seed: UInt64 = 0x8250_59AD_1F00_0001
        #if targetEnvironment(simulator)
        let environment = "simulator-not-iphone-hardware"
        #else
        let environment = "device-short-run-not-thermal-qualification"
        #endif
        #if compiler(>=6.2)
        let compiler = "swift-ge-6.2"
        #elseif compiler(>=6.0)
        let compiler = "swift-ge-6.0-lt-6.2"
        #else
        let compiler = "swift-lt-6.0"
        #endif
        for depth in [8, 10] {
            for pattern in [NativePattern.random, .directionChanging, .tieHeavy, .gradient] {
                // All fixtures, output buffers and sample capacity are prepared
                // before timing. Each sample produces both fields and both planes.
                let inputs = try [1, 2].map { components in
                    try (0..<3).map { frame in
                        let plane = try NativePlane(width: width / components,
                            height: height / components, components: components, depth: depth,
                            padding: 16)
                        plane.fill(pattern: pattern, frame: frame, seed: seed)
                        return plane
                    }
                }
                let scalarOutputs = try (0..<2).map { _ in
                    try inputs.map { try NativePlane(like: $0[1], padding: 16) }
                }
                let neonOutputs = try (0..<2).map { _ in
                    try inputs.map { try NativePlane(like: $0[1], padding: 16) }
                }
                let scalarWarmup = runNativePair(inputs, outputs: scalarOutputs, backend: .scalar)
                let neonWarmup = runNativePair(inputs, outputs: neonOutputs, backend: .neon)
                guard scalarWarmup.status == 0, neonWarmup.status == 0, neonWarmup.blocks > 0 else {
                    XCTFail("A/B warmup must succeed with executed NEON blocks: scalar=\(scalarWarmup.status), neon=\(neonWarmup.status), blocks=\(neonWarmup.blocks)")
                    return
                }
                for field in 0..<2 {
                    for plane in 0..<2 {
                        // Fail before collecting any timings for unequal pixels.
                        guard scalarOutputs[field][plane].snapshot() == neonOutputs[field][plane].snapshot() else {
                            XCTFail("Scalar/NEON equality failed before timing: \(pattern.rawValue), depth=\(depth)")
                            return
                        }
                    }
                }
                var scalarMilliseconds: [Double] = []
                var neonMilliseconds: [Double] = []
                scalarMilliseconds.reserveCapacity(7)
                neonMilliseconds.reserveCapacity(7)
                for sample in 0..<7 {
                    let order: [NativeBackend] = sample.isMultiple(of: 2) ? [.scalar, .neon] : [.neon, .scalar]
                    for backend in order {
                        let outputs = backend == .scalar ? scalarOutputs : neonOutputs
                        let start = ContinuousClock.now
                        let result = runNativePair(inputs, outputs: outputs, backend: backend)
                        let elapsed = cpuBenchmarkMilliseconds(since: start)
                        guard result.status == 0, backend == .scalar || result.blocks == neonWarmup.blocks else {
                            XCTFail("A/B sample did not execute the requested backend: \(backend), status=\(result.status), blocks=\(result.blocks)")
                            return
                        }
                        if backend == .scalar {
                            scalarMilliseconds.append(elapsed)
                        } else {
                            neonMilliseconds.append(elapsed)
                        }
                    }
                }
                for field in 0..<2 {
                    for plane in 0..<2 {
                        XCTAssertEqual(scalarOutputs[field][plane].snapshot(), neonOutputs[field][plane].snapshot())
                    }
                }
                emitCPUBenchmark("IOS_CPU_YADIF_AB_BENCH width=\(width) height=\(height) depth=\(depth) pattern=\(pattern.rawValue) seed=\(seed) scalar_pair_ms=\(scalarMilliseconds) neon_pair_ms=\(neonMilliseconds) vector_blocks=\(neonWarmup.blocks) order=alternating samples=7 workers=1 backend=direct-c flags=same-translation-unit compiler=\(compiler) os=\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.patchVersion) environment=\(environment) configuration=release")
            }
        }
    }

    private func runNativePair(_ inputs: [[NativePlane]], outputs: [[NativePlane]],
        backend: NativeBackend) -> NativeResult {
        var blocks = 0
        for field in 0..<2 {
            for plane in 0..<2 {
                let result = runNativePlane(inputs[plane], output: outputs[field][plane],
                    backend: backend, outputIndex: field, topFieldFirst: true, spatialOnly: false)
                guard result.status == 0 else { return result }
                blocks += result.blocks
            }
        }
        return NativeResult(status: 0, blocks: blocks)
    }
    #endif

    private func requireNativeNEON(file: StaticString = #filePath, line: UInt = #line) throws {
        #if arch(arm64)
        XCTAssertEqual(VPYADIFNEONAvailable(), 1, "arm64 must compile NEON; fallback is not parity evidence", file: file, line: line)
        guard VPYADIFNEONAvailable() == 1 else { throw SyntheticFailure() }
        #else
        guard VPYADIFNEONAvailable() == 1 else { throw XCTSkip("Required NEON execution needs an arm64 native runner") }
        #endif
    }

    private enum NativeBackend: Int32 { case automatic = -1, scalar = 0, neon = 1 }
    private enum NativePattern: String, CaseIterable {
        case random, directionChanging = "direction-changing", tieHeavy = "tie-heavy", gradient, extremes
    }
    private enum NativeGuardEdge { case none, leading, trailing }
    private struct NativeResult { let status: Int32; let blocks: Int }
    private struct NativeRandom {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private func runNativePlane(_ inputs: [NativePlane], output: NativePlane,
        backend: NativeBackend, outputIndex: Int, topFieldFirst: Bool, spatialOnly: Bool,
        firstRow: Int = 0, rowCount: Int? = nil, outputByteOffset: Int = 0) -> NativeResult {
        let current = inputs[1]
        let destination = output.base.advanced(by: outputByteOffset)
        let count = rowCount ?? current.height
        var blocks = 0x825 // API must reset this per call, including rejected calls.
        let status: Int32
        switch backend {
        case .automatic:
            status = VPYADIFProcessPlaneRows(inputs[0].base, inputs[0].stride,
                current.base, current.stride, inputs[2].base, inputs[2].stride,
                destination, output.stride, Int32(current.width), Int32(current.height),
                Int32(current.components), Int32(current.depth), Int32(outputIndex),
                topFieldFirst ? 1 : 0, spatialOnly ? 1 : 0, Int32(firstRow), Int32(count))
            blocks = 0
        case .scalar:
            status = VPYADIFProcessPlaneRowsScalar(inputs[0].base, inputs[0].stride,
                current.base, current.stride, inputs[2].base, inputs[2].stride,
                destination, output.stride, Int32(current.width), Int32(current.height),
                Int32(current.components), Int32(current.depth), Int32(outputIndex),
                topFieldFirst ? 1 : 0, spatialOnly ? 1 : 0, Int32(firstRow), Int32(count))
            blocks = 0
        case .neon:
            status = VPYADIFProcessPlaneRowsWithBackend(inputs[0].base, inputs[0].stride,
                current.base, current.stride, inputs[2].base, inputs[2].stride,
                destination, output.stride, Int32(current.width), Int32(current.height),
                Int32(current.components), Int32(current.depth), Int32(outputIndex),
                topFieldFirst ? 1 : 0, spatialOnly ? 1 : 0, Int32(firstRow), Int32(count),
                backend.rawValue, &blocks)
        }
        return NativeResult(status: status, blocks: blocks)
    }

    private func assertNativeParity(_ inputs: [NativePlane], outputIndex: Int,
        topFieldFirst: Bool, spatialOnly: Bool, padding: Int, offset: Int,
        label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let scalar = try NativePlane(like: inputs[1], padding: padding, offset: offset)
        let candidate = try NativePlane(like: inputs[1], padding: padding, offset: offset)
        let automatic = try NativePlane(like: inputs[1], padding: padding, offset: offset)
        XCTAssertEqual(runNativePlane(inputs, output: scalar, backend: .scalar,
            outputIndex: outputIndex, topFieldFirst: topFieldFirst, spatialOnly: spatialOnly).status,
            0, label, file: file, line: line)
        let result = runNativePlane(inputs, output: candidate, backend: .neon,
            outputIndex: outputIndex, topFieldFirst: topFieldFirst, spatialOnly: spatialOnly)
        let hasBlocks = (candidate.width - 6) * candidate.components >= 8 && VPYADIFNEONAvailable() == 1
        XCTAssertEqual(result.status, hasBlocks ? 0 : -2, label, file: file, line: line)
        if hasBlocks {
            XCTAssertGreaterThan(result.blocks, 0, label, file: file, line: line)
            XCTAssertEqual(candidate.snapshot(), scalar.snapshot(), label, file: file, line: line)
            candidate.assertUnwrittenBytes(firstRow: 0, rowCount: candidate.height, file: file, line: line)
        } else {
            XCTAssertEqual(result.blocks, 0, label, file: file, line: line)
            XCTAssertTrue(candidate.snapshot().allSatisfy { $0 == NativePlane.sentinel }, label, file: file, line: line)
        }
        XCTAssertEqual(runNativePlane(inputs, output: automatic, backend: .automatic,
            outputIndex: outputIndex, topFieldFirst: topFieldFirst, spatialOnly: spatialOnly).status,
            0, label, file: file, line: line)
        XCTAssertEqual(automatic.snapshot(), scalar.snapshot(), "auto \(label)", file: file, line: line)
        automatic.assertUnwrittenBytes(firstRow: 0, rowCount: automatic.height, file: file, line: line)
        if candidate.depth == 10 {
            let packed = scalar.packedBytes()
            XCTAssertTrue(stride(from: 0, to: packed.count, by: 2).allSatisfy { packed[$0] & 0x3F == 0 },
                "P010 low bits \(label)", file: file, line: line)
        }
    }

    private final class NativePlane {
        static let sentinel: UInt8 = 0xA5
        let width: Int
        let height: Int
        let components: Int
        let depth: Int
        let rowBytes: Int
        let stride: Int
        let base: UnsafeMutablePointer<UInt8>
        private let storage: UnsafeMutableRawPointer
        private let storageBytes: Int
        private let dataOffset: Int
        private let mapping: UnsafeMutableRawPointer?
        private let mappingBytes: Int

        init(width: Int, height: Int, components: Int, depth: Int,
            padding: Int = 0, offset: Int = 0, guardEdge: NativeGuardEdge = .none) throws {
            let rowBytes = width * components * (depth == 8 ? 1 : 2)
            let planeStride = rowBytes + padding
            let planeBytes = planeStride * height
            let allocatedStorage: UnsafeMutableRawPointer
            let allocatedBytes: Int
            let dataOffset: Int
            let mapping: UnsafeMutableRawPointer?
            let mappingBytes: Int
            if guardEdge == .none {
                dataOffset = 32 + offset
                allocatedBytes = dataOffset + planeBytes + 32
                allocatedStorage = UnsafeMutableRawPointer.allocate(byteCount: allocatedBytes, alignment: 16)
                mapping = nil
                mappingBytes = 0
            } else {
                let pageSize = Int(getpagesize())
                allocatedBytes = ((planeBytes + pageSize - 1) / pageSize) * pageSize
                mappingBytes = allocatedBytes + pageSize * 2
                let address = mmap(nil, mappingBytes, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
                guard let address, address != MAP_FAILED else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let writable = address.advanced(by: pageSize)
                guard mprotect(writable, allocatedBytes, PROT_READ | PROT_WRITE) == 0 else {
                    let error = errno
                    munmap(address, mappingBytes)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
                }
                mapping = address
                allocatedStorage = writable
                dataOffset = guardEdge == .leading ? 0 : allocatedBytes - planeBytes
            }
            allocatedStorage.initializeMemory(as: UInt8.self, repeating: Self.sentinel, count: allocatedBytes)
            self.width = width
            self.height = height
            self.components = components
            self.depth = depth
            self.rowBytes = rowBytes
            stride = planeStride
            storage = allocatedStorage
            storageBytes = allocatedBytes
            self.dataOffset = dataOffset
            self.mapping = mapping
            self.mappingBytes = mappingBytes
            base = allocatedStorage.advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
        }

        convenience init(like source: NativePlane, padding: Int = 0, offset: Int = 0,
            guardEdge: NativeGuardEdge = .none) throws {
            try self.init(width: source.width, height: source.height, components: source.components,
                depth: source.depth, padding: padding, offset: offset, guardEdge: guardEdge)
        }

        deinit {
            if let mapping { munmap(mapping, mappingBytes) } else { storage.deallocate() }
        }

        func snapshot() -> [UInt8] {
            Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: UInt8.self), count: storageBytes))
        }

        func packedBytes() -> Data {
            var packed = Data(capacity: rowBytes * height)
            for row in 0..<height { packed.append(base.advanced(by: row * stride), count: rowBytes) }
            return packed
        }

        func copyPacked(_ packed: Data) {
            precondition(packed.count == rowBytes * height)
            packed.withUnsafeBytes { bytes in
                for row in 0..<height {
                    UnsafeMutableRawPointer(base.advanced(by: row * stride)).copyMemory(
                        from: bytes.baseAddress!.advanced(by: row * rowBytes), byteCount: rowBytes)
                }
            }
        }

        func fill(pattern: NativePattern, frame: Int, seed: UInt64) {
            let maximum = (1 << depth) - 1
            var random = NativeRandom(state: seed &+ UInt64(frame) &* 0x1_0001)
            for y in 0..<height {
                for x in 0..<width {
                    for component in 0..<components {
                        let sample = x * components + component
                        let value: Int
                        switch pattern {
                        case .random:
                            value = Int(random.next() & UInt64(maximum))
                        case .directionChanging:
                            let direction = ((x / 8 + y / 4) & 1) == 0 ? 1 : -1
                            value = ((x + direction * y + frame * 3) * 47 + component * 109) & maximum
                        case .tieHeavy:
                            // Flat plateaus produce equal directional scores;
                            // the small palette makes nonzero ties frequent too.
                            value = (x / 16).isMultiple(of: 2) ? maximum / 2 : Int(random.next() & 3) * (maximum / 3)
                        case .gradient:
                            value = (sample * 13 + y * 17 + frame * 31) & maximum
                        case .extremes:
                            switch (x + y + component + frame) & 3 {
                            case 0: value = 0
                            case 1: value = maximum
                            case 2: value = 1
                            default: value = maximum - 1
                            }
                        }
                        let address = base.advanced(by: y * stride + sample * (depth == 8 ? 1 : 2))
                        if depth == 8 {
                            address.pointee = UInt8(value)
                        } else {
                            // Byte stores deliberately support odd addresses and
                            // poison low bits, which both backends must clear.
                            let word = (value << 6) | Int(random.next() & 0x3F)
                            address[0] = UInt8(truncatingIfNeeded: word)
                            address[1] = UInt8(truncatingIfNeeded: word >> 8)
                        }
                    }
                }
            }
        }

        func setCode(_ value: Int, sample: Int, row: Int, lowBits: Int = 0) {
            let address = base.advanced(by: row * stride + sample * (depth == 8 ? 1 : 2))
            if depth == 8 {
                address[0] = UInt8(value)
            } else {
                let word = (value << 6) | lowBits
                address[0] = UInt8(truncatingIfNeeded: word)
                address[1] = UInt8(truncatingIfNeeded: word >> 8)
            }
        }

        func code(sample: Int, row: Int) -> Int {
            let address = base.advanced(by: row * stride + sample * (depth == 8 ? 1 : 2))
            return depth == 8 ? Int(address[0]) : (Int(address[0]) | (Int(address[1]) << 8)) >> 6
        }

        func assertUnchangedOutsideRows(_ before: [UInt8], rows: Range<Int>,
            file: StaticString = #filePath, line: UInt = #line) {
            let bytes = storage.assumingMemoryBound(to: UInt8.self)
            for offset in 0..<storageBytes {
                let relative = offset - dataOffset
                let requested = relative >= 0 && relative < stride * height &&
                    rows.contains(relative / stride) && relative % stride < rowBytes
                if !requested && bytes[offset] != before[offset] {
                    XCTFail("Partition wrote outside requested pixels at byte \(offset)", file: file, line: line)
                    return
                }
            }
        }

        func assertUnwrittenBytes(firstRow: Int, rowCount: Int,
            file: StaticString = #filePath, line: UInt = #line) {
            let bytes = storage.assumingMemoryBound(to: UInt8.self)
            for offset in 0..<storageBytes {
                let relative = offset - dataOffset
                let isOutput = relative >= 0 && relative < stride * height &&
                    relative / stride >= firstRow && relative / stride < firstRow + rowCount &&
                    relative % stride < rowBytes
                if !isOutput && bytes[offset] != Self.sentinel {
                    XCTFail("Output wrote padding, a guard byte or an unrequested row at byte \(offset)", file: file, line: line)
                    return
                }
            }
        }
    }

    func testCPUAdapterMatchesEveryPinnedNV12AndP010FieldExactly() throws {
        for (format, name, bytesPerFrame) in [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "nv12", Self.nv12BytesPerFrame),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "p010", Self.p010BytesPerFrame),
        ] {
            for (order, stem) in [(FieldParity.top, "tff"), (FieldParity.bottom, "bff")] {
                let inputBytes = try fixture("yadif-\(name)-\(stem)-input.bin")
                let expected = try fixture("yadif-\(name)-\(stem).bin")
                let inputs = try (0..<5).map { index in
                    try makePixelBuffer(pixelFormat: format,
                        bytes: inputBytes.subdata(in: index * bytesPerFrame..<(index + 1) * bytesPerFrame))
                }
                let pool = ProgressiveSurfacePool()
                var actual = Data()
                for center in 1...3 {
                    let outputs = try pool.allocatePair(matching: inputs[center])
                    try CPUVideoProcessing.yadif(job: YADIFJob(
                        previous: normalized(inputs[center - 1], id: UInt64(center)),
                        current: normalized(inputs[center], id: UInt64(center + 1)),
                        next: normalized(inputs[center + 1], id: UInt64(center + 2)),
                        order: resolved(order), spatialOnly: false), outputs: outputs)
                    actual.append(try packedBytes(outputs.first))
                    actual.append(try packedBytes(outputs.second))
                }
                XCTAssertEqual(actual, expected, "\(name) \(stem) CPU adapter")
            }
        }
    }
    #endif

    func testMapperSelectsExactNV12AndP010PlaneFormatsForVideoAndFullRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        for (pixelFormat, expectedLuma, expectedChroma) in [
            (
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                MTLPixelFormat.r8Uint,
                MTLPixelFormat.rg8Uint
            ),
            (
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                MTLPixelFormat.r8Uint,
                MTLPixelFormat.rg8Uint
            ),
            (
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                MTLPixelFormat.r16Uint,
                MTLPixelFormat.rg16Uint
            ),
            (
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                MTLPixelFormat.r16Uint,
                MTLPixelFormat.rg16Uint
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
        XCTAssertTrue(metal.contains("kernel void yadifChroma8"))
        XCTAssertTrue(metal.contains("kernel void yadifChroma16"))
        XCTAssertTrue(metal.contains("threadgroup_barrier"))
        XCTAssertTrue(metal.contains("[[threadgroup(0)]]"))
        XCTAssertTrue(lowLevelSwift.contains("setThreadgroupMemoryLength"))
        // A per-sample component index taken from a uniform cannot live in a
        // register, so every one of the two dozen samples a synthesized pixel
        // takes would round-trip through scratch memory.
        XCTAssertFalse(metal.contains("componentCount"))
        XCTAssertFalse(metal.lowercased().contains("placeholder"))
    }

    func testThreadgroupLayoutCapsHeightAndHonorsDynamicMemoryLimit() {
        let layout = YADIFThreadgroupLayout.make(
            destinationWidth: 1_920,
            rowPairCount: 540,
            threadExecutionWidth: 32,
            maxTotalThreadsPerThreadgroup: 128,
            bytesPerCode: MemoryLayout<SIMD2<Int16>>.stride,
            maximumDynamicMemoryLength: 4_096
        )

        XCTAssertEqual(layout.threads.width, 32)
        XCTAssertEqual(layout.threads.height, 4)
        XCTAssertEqual(layout.threads.depth, 1)
        XCTAssertLessThanOrEqual(layout.threads.height, YADIFThreadgroupLayout.maximumTileHeight)
        XCTAssertLessThanOrEqual(layout.memoryLength, 4_096)
        XCTAssertEqual(layout.memoryLength, 1_216)
        XCTAssertEqual(layout.memoryLength % 16, 0)
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
                    dimensions: .init(width: Int32(CVPixelBufferGetWidth(pixelBuffer)), height: Int32(CVPixelBufferGetHeight(pixelBuffer))),
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
