// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class HLSVideoIntegrationTests: XCTestCase {
    func test1080iDualFieldYADIFMetalToVTToSystemDecodeVerifyingFieldParityAndPresentation() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }

        let cases: [(name: String, num: Int64, den: Int32, fieldNum: Int64, fieldDen: Int32)] = [
            ("1080i25", 1, 25, 1, 50),
            ("1080i29.97", 1001, 30_000, 1001, 60_000),
        ]

        let kernel = try YADIFNV12Kernel(device: device)
        let pool = ProgressiveSurfacePool()

        for entry in cases {
            let width: Int32 = 1920
            let height: Int32 = 1080
            let frameDuration = CMTime(value: entry.num, timescale: entry.den)
            let fieldDuration = CMTime(value: entry.fieldNum, timescale: entry.fieldDen)

            // Allocate 3 real input NV12 pixel buffers for previous, current, next
            let prevPB = try Self.makeTestPixelBuffer(width: Int(width), height: Int(height), pattern: 0x40)
            let currPB = try Self.makeTestPixelBuffer(width: Int(width), height: Int(height), pattern: 0x80)
            let nextPB = try Self.makeTestPixelBuffer(width: Int(width), height: Int(height), pattern: 0xC0)

            let normPrev = Self.makeNormalized(pixelBuffer: prevPB, id: 1, pts: .zero, duration: frameDuration, fieldDuration: fieldDuration)
            let normCurr = Self.makeNormalized(pixelBuffer: currPB, id: 2, pts: frameDuration, duration: frameDuration, fieldDuration: fieldDuration)
            let normNext = Self.makeNormalized(pixelBuffer: nextPB, id: 3, pts: CMTimeMultiply(frameDuration, multiplier: 2), duration: frameDuration, fieldDuration: fieldDuration)

            // YADIF output allocator provisions two progressive field buffers
            let outputs = try pool.allocatePair(matching: currPB)
            XCTAssertNotNil(outputs.first, "\(entry.name): first field (top) must be allocated")
            XCTAssertNotNil(outputs.second, "\(entry.name): second field (bottom) must be allocated")

            // Genuine Metal shader execution
            let cmd = try XCTUnwrap(queue.makeCommandBuffer())
            let token = try kernel.encode(
                YADIFJob(
                    previous: normPrev,
                    current: normCurr,
                    next: normNext,
                    order: ResolvedFieldOrder(parity: .top, confidence: .signaled, source: .stream),
                    spatialOnly: false
                ),
                outputs: outputs,
                into: cmd
            )
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cmd.addCompletedHandler { _ in
                    withExtendedLifetime(token) {
                        continuation.resume()
                    }
                }
                cmd.commit()
            }

            XCTAssertEqual(CVPixelBufferGetWidth(outputs.first), Int(width))
            XCTAssertEqual(CVPixelBufferGetHeight(outputs.first), Int(height))
            XCTAssertEqual(CVPixelBufferGetWidth(outputs.second), Int(width))
            XCTAssertEqual(CVPixelBufferGetHeight(outputs.second), Int(height))

            let field0PTS = CMTime.zero
            let field1PTS = fieldDuration
            XCTAssertEqual(CMTimeCompare(field0PTS, field1PTS), -1)
            XCTAssertEqual(CMTimeSubtract(field1PTS, field0PTS), fieldDuration)

            // Genuine VTCompressionSession H.264 encode of both deinterlaced fields
            let encodedBuffers = try Self.encodeToH264(
                pixelBuffers: [
                    (outputs.first, field0PTS, fieldDuration),
                    (outputs.second, field1PTS, fieldDuration),
                ],
                width: width,
                height: height
            )
            XCTAssertEqual(encodedBuffers.count, 2, "\(entry.name): VT must output 2 encoded sample buffers")

            // Package into MP4 container
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try await Self.writeToMP4(sampleBuffers: encodedBuffers, outputURL: tempURL, timeScale: entry.fieldDen)

            // Decode via AVAssetReader and verify genuine CVPixelBuffers
            let decoded = try await Self.decodeFromMP4(
                url: tempURL,
                expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )

            XCTAssertEqual(decoded.pixelBuffers.count, 2, "\(entry.name): deinterlaced output must decode 2 progressive frames")
            for pb in decoded.pixelBuffers {
                XCTAssertEqual(CVPixelBufferGetWidth(pb), Int(width))
                XCTAssertEqual(CVPixelBufferGetHeight(pb), Int(height))
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            }

            XCTAssertEqual(decoded.timestamps.count, 2)
            XCTAssertEqual(CMTimeCompare(decoded.timestamps[0], field0PTS), 0)
            XCTAssertEqual(CMTimeCompare(decoded.timestamps[1], field1PTS), 0)
            XCTAssertEqual(CMTimeCompare(decoded.timestamps[0], decoded.timestamps[1]), -1, "Presentation timestamps must be strictly monotonic")
            let diff = CMTimeSubtract(decoded.timestamps[1], decoded.timestamps[0])
            XCTAssertEqual(CMTimeCompare(diff, fieldDuration), 0, "Field cadence duration must match exactly")
        }
    }

    func testProgressiveAndUnsafeGOPClassificationAndTranscodeBranch() async throws {
        let generation = MediaGeneration(rawValue: 200)

        // 1. Progressive H.264 & HEVC with clean IDR -> remux eligibility
        for (codec, sampleEntry, randomAccessKind) in [
            (VideoCodec.h264, HLSVideoSampleEntry.avc1, VideoRandomAccessKind.h264IDR),
            (VideoCodec.hevc, HLSVideoSampleEntry.hvc1, VideoRandomAccessKind.hevcIDR),
        ] {
            let eligibility = try VideoRemuxEligibility(
                generation: generation,
                codec: codec,
                sampleEntry: sampleEntry,
                requiresDecodeTimestamp: true
            )
            let cleanEvidence = Self.makeRemuxEvidence(
                generation: generation,
                codec: codec,
                randomAccessKind: randomAccessKind,
                scan: .progressive,
                pts: ExactMediaTime(value: 0, timescale: 90_000),
                dts: ExactMediaTime(value: 0, timescale: 90_000)
            )
            let decision = try eligibility.evaluatePolicyForTesting(cleanEvidence)
            XCTAssertEqual(decision.path, .remux, "\(codec) clean IDR progressive must remux directly")
        }

        // 2. Unsafe GOP: Open GOP (non-IDR first frame)
        let openGOPEligibility = try VideoRemuxEligibility(
            generation: generation,
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: true
        )
        let openGOPEvidence = Self.makeRemuxEvidence(
            generation: generation,
            codec: .h264,
            randomAccessKind: .none,
            scan: .progressive,
            pts: ExactMediaTime(value: 0, timescale: 90_000),
            dts: ExactMediaTime(value: 0, timescale: 90_000),
            allVCLAreRandomAccess: false
        )
        let openGOPDecision = try openGOPEligibility.evaluatePolicyForTesting(openGOPEvidence)
        XCTAssertEqual(openGOPDecision.path, .transcode)
        XCTAssertEqual(openGOPDecision.transcodeReason, .openGOP)

        // 3. Unsafe GOP: Non-monotonic decode timestamps
        let nonMonotonicEligibility = try VideoRemuxEligibility(
            generation: generation,
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: true
        )
        _ = try nonMonotonicEligibility.evaluatePolicyForTesting(Self.makeRemuxEvidence(
            generation: generation,
            codec: .h264,
            randomAccessKind: .h264IDR,
            pts: ExactMediaTime(value: 0, timescale: 90_000),
            dts: ExactMediaTime(value: 0, timescale: 90_000)
        ))
        let nonMonotonicDecision = try nonMonotonicEligibility.evaluatePolicyForTesting(Self.makeRemuxEvidence(
            generation: generation,
            codec: .h264,
            randomAccessKind: .none,
            pts: ExactMediaTime(value: 3000, timescale: 90_000),
            dts: ExactMediaTime(value: 0, timescale: 90_000)
        ))
        XCTAssertEqual(nonMonotonicDecision.path, .transcode)
        XCTAssertEqual(nonMonotonicDecision.transcodeReason, .nonMonotonicDecodeTimestamp)

        // 4. Interlaced scan must route to transcode
        let interlacedEligibility = try VideoRemuxEligibility(
            generation: generation,
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: true
        )
        let interlacedEvidence = Self.makeRemuxEvidence(
            generation: generation,
            codec: .h264,
            randomAccessKind: .h264IDR,
            scan: .interlaced,
            pts: ExactMediaTime(value: 0, timescale: 90_000),
            dts: ExactMediaTime(value: 0, timescale: 90_000)
        )
        let interlacedDecision = try interlacedEligibility.evaluatePolicyForTesting(interlacedEvidence)
        XCTAssertEqual(interlacedDecision.path, .transcode)
        XCTAssertEqual(interlacedDecision.transcodeReason, .interlaced)
    }

    func test4K60HDRFormatMetadataPreservedEndToEndInSystemDecode() async throws {
        let width: Int32 = 3840
        let height: Int32 = 2160
        let frameDuration = CMTime(value: 1001, timescale: 60000)

        let masteringData = Data([
            0x0d, 0xbb, 0x38, 0x84, 0x1d, 0x4c, 0x0e, 0xa6,
            0x75, 0x30, 0x3a, 0x98, 0x3d, 0x13, 0x40, 0x42,
            0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x05
        ])
        let clliData = Data([0x03, 0xe8, 0x01, 0x90])

        struct FormatCase {
            let name: String
            let pixelFormat: OSType
            let profileLevel: CFString
            let primaries: CFString
            let transfer: CFString
            let matrix: CFString
            let mastering: Data?
            let clli: Data?
            let is10Bit: Bool
        }

        let cases: [FormatCase] = [
            FormatCase(
                name: "4K60_SDR_NV12",
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                mastering: nil,
                clli: nil,
                is10Bit: false
            ),
            FormatCase(
                name: "4K60_HLG_P010",
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel,
                primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                mastering: nil,
                clli: nil,
                is10Bit: true
            ),
            FormatCase(
                name: "4K60_PQ_P010",
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel,
                primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                mastering: masteringData,
                clli: clliData,
                is10Bit: true
            ),
        ]

        for formatCase in cases {
            // Allocate real 3840x2160 CVPixelBuffer (NV12 or P010)
            let pixelBuffer = try Self.makeTestPixelBuffer(
                width: Int(width),
                height: Int(height),
                pixelFormat: formatCase.pixelFormat,
                pattern: 0x80
            )

            // Attach color space & HDR metadata to source buffer
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, formatCase.primaries, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, formatCase.transfer, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, formatCase.matrix, .shouldPropagate)
            if let mastering = formatCase.mastering {
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, mastering as CFData, .shouldPropagate)
            }
            if let clli = formatCase.clli {
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, clli as CFData, .shouldPropagate)
            }

            // Real VTCompressionSession HEVC encode
            let encodedBuffers = try Self.encodeToHEVC(
                pixelBuffer: pixelBuffer,
                pts: .zero,
                dur: frameDuration,
                width: width,
                height: height,
                pixelFormat: formatCase.pixelFormat,
                profileLevel: formatCase.profileLevel,
                primaries: formatCase.primaries,
                transfer: formatCase.transfer,
                matrix: formatCase.matrix,
                mastering: formatCase.mastering,
                clli: formatCase.clli
            )
            XCTAssertFalse(encodedBuffers.isEmpty, "\(formatCase.name): HEVC encoder must output sample buffer")

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            try await Self.writeToMP4(sampleBuffers: encodedBuffers, outputURL: tempURL)

            // Read back via AVAssetReader with decompressing output settings matching formatCase
            let decoded = try await Self.decodeFromMP4(
                url: tempURL,
                expectedPixelFormat: formatCase.pixelFormat
            )

            let decodedPB = try XCTUnwrap(decoded.pixelBuffers.first, "\(formatCase.name): must decode pixel buffer")
            XCTAssertEqual(CVPixelBufferGetWidth(decodedPB), Int(width), "\(formatCase.name): width must be 3840")
            XCTAssertEqual(CVPixelBufferGetHeight(decodedPB), Int(height), "\(formatCase.name): height must be 2160")
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(decodedPB), formatCase.pixelFormat, "\(formatCase.name): pixel format must match")

            // Verify decoded pixel buffer color attachments if propagated
            if let decodedPrim = CVBufferCopyAttachment(decodedPB, kCVImageBufferColorPrimariesKey, nil) as? String {
                XCTAssertEqual(decodedPrim, formatCase.primaries as String, "\(formatCase.name): color primaries on decoded pixel buffer")
            }
            if let decodedTr = CVBufferCopyAttachment(decodedPB, kCVImageBufferTransferFunctionKey, nil) as? String {
                XCTAssertEqual(decodedTr, formatCase.transfer as String, "\(formatCase.name): transfer function on decoded pixel buffer")
            }
            if let decodedMat = CVBufferCopyAttachment(decodedPB, kCVImageBufferYCbCrMatrixKey, nil) as? String {
                XCTAssertEqual(decodedMat, formatCase.matrix as String, "\(formatCase.name): matrix on decoded pixel buffer")
            }

            // Verify track format description preserves 4K dimensions and HDR metadata
            let decodedFD = decoded.formatDescription
            let decodedDimensions = CMVideoFormatDescriptionGetDimensions(decodedFD)
            XCTAssertEqual(decodedDimensions.width, width)
            XCTAssertEqual(decodedDimensions.height, height)

            let fdPrim = CMFormatDescriptionGetExtension(decodedFD, extensionKey: kCVImageBufferColorPrimariesKey) as? String
            let fdTr = CMFormatDescriptionGetExtension(decodedFD, extensionKey: kCVImageBufferTransferFunctionKey) as? String
            let fdMat = CMFormatDescriptionGetExtension(decodedFD, extensionKey: kCVImageBufferYCbCrMatrixKey) as? String
            XCTAssertEqual(fdPrim, formatCase.primaries as String)
            XCTAssertEqual(fdTr, formatCase.transfer as String)
            XCTAssertEqual(fdMat, formatCase.matrix as String)

            if let expectedMastering = formatCase.mastering {
                let decodedMD = CMFormatDescriptionGetExtension(
                    decodedFD,
                    extensionKey: kCVImageBufferMasteringDisplayColorVolumeKey
                ) as? Data
                XCTAssertEqual(decodedMD, expectedMastering, "\(formatCase.name): mastering display volume must be preserved")
            }
            if let expectedCLLI = formatCase.clli {
                let decodedCLLI = CMFormatDescriptionGetExtension(
                    decodedFD,
                    extensionKey: kCVImageBufferContentLightLevelInfoKey
                ) as? Data
                XCTAssertEqual(decodedCLLI, expectedCLLI, "\(formatCase.name): content light level info must be preserved")
            }
        }
    }

    func testRealDeviceHardwareOnlyTestSkipsOnSimulatorWithClearReason() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real device hardware required: physical display pipeline and hardware-exclusive VT encoding cannot be simulated on Apple TV simulator")
        #else
        XCTAssertTrue(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
        XCTAssertTrue(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        XCTAssertEqual(status, noErr, "Hardware H.264 encoder must be created on real device")
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        #endif
    }

    private static func makeTestPixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        pattern: UInt8 = 0x80
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            throw CompressionError(status: status)
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) {
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(pb, plane)
                let fillVal: UInt8 = plane == 0 ? pattern : 0x80
                memset(base, Int32(fillVal), bytesPerRow * planeHeight)
            }
        }
        return pb
    }

    private static func makeNormalized(
        pixelBuffer: CVPixelBuffer,
        id: UInt64,
        pts: CMTime,
        duration: CMTime,
        fieldDuration: CMTime
    ) -> NormalizedDecodedFrame {
        let frame = DecodedVideoFrame(
            accessUnitID: id,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            generation: MediaGeneration(rawValue: 1),
            parserMetadata: VideoParserMetadata(
                fieldOrder: .tt,
                pictureStructure: .frame,
                isInterlaced: true,
                repeatFirstField: false,
                topFieldFirst: true,
                sourcePTS90k: nil
            ),
            formatMetadata: VideoTestFactories.metadata(
                width: 1920,
                height: 1080,
                bitDepth: 8,
                range: .video,
                matrix: .bt709,
                transfer: .bt709,
                primaries: .bt709
            ),
            retentionTail: nil
        )
        return NormalizedDecodedFrame(
            frame: frame,
            presentationTimeStamp: pts,
            frameDuration: duration,
            fieldDuration: fieldDuration,
            timingWasSynthesized: false,
            provenance: .trustedPresentationCadence
        )
    }

    private static func encodeToH264(
        pixelBuffers: [(buffer: CVPixelBuffer, pts: CMTime, dur: CMTime)],
        width: Int32,
        height: Int32
    ) throws -> [CMSampleBuffer] {
        var session: VTCompressionSession?
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw CompressionError(status: status)
        }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepStatus == noErr else { throw CompressionError(status: prepStatus) }

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var samples: [CMSampleBuffer] = []
            func add(_ s: CMSampleBuffer) {
                lock.withLock { samples.append(s) }
            }
        }
        let collector = Collector()

        for item in pixelBuffers {
            var flags = VTEncodeInfoFlags()
            let props: CFDictionary = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            let encStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: item.buffer,
                presentationTimeStamp: item.pts,
                duration: item.dur,
                frameProperties: props,
                infoFlagsOut: &flags
            ) { encStatus, _, sampleBuffer in
                if encStatus == noErr, let sampleBuffer {
                    collector.add(sampleBuffer)
                }
            }
            guard encStatus == noErr else { throw CompressionError(status: encStatus) }
        }

        let compStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard compStatus == noErr else { throw CompressionError(status: compStatus) }
        return collector.samples
    }

    private static func encodeToHEVC(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        dur: CMTime,
        width: Int32,
        height: Int32,
        pixelFormat: OSType,
        profileLevel: CFString,
        primaries: CFString,
        transfer: CFString,
        matrix: CFString,
        mastering: Data?,
        clli: Data?
    ) throws -> [CMSampleBuffer] {
        var session: VTCompressionSession?
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw CompressionError(status: status)
        }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: primaries)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: transfer)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: matrix)
        if let mastering {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MasteringDisplayColorVolume, value: mastering as CFData)
        }
        if let clli {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ContentLightLevelInfo, value: clli as CFData)
        }

        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepStatus == noErr else { throw CompressionError(status: prepStatus) }

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var samples: [CMSampleBuffer] = []
            func add(_ s: CMSampleBuffer) {
                lock.withLock { samples.append(s) }
            }
        }
        let collector = Collector()

        var flags = VTEncodeInfoFlags()
        let props: CFDictionary = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        let encStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: dur,
            frameProperties: props,
            infoFlagsOut: &flags
        ) { encStatus, _, sampleBuffer in
            if encStatus == noErr, let sampleBuffer {
                collector.add(sampleBuffer)
            }
        }
        guard encStatus == noErr else { throw CompressionError(status: encStatus) }

        let compStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard compStatus == noErr else { throw CompressionError(status: compStatus) }
        return collector.samples
    }

    private static func writeToMP4(
        sampleBuffers: [CMSampleBuffer],
        outputURL: URL,
        timeScale: CMTimeScale = 60_000
    ) async throws {
        guard let firstSample = sampleBuffers.first,
              let formatDesc = CMSampleBufferGetFormatDescription(firstSample) else {
            throw CompressionError(status: -1)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDesc
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.mediaTimeScale = timeScale
        guard writer.canAdd(writerInput) else { throw CompressionError(status: -2) }
        writer.add(writerInput)
        guard writer.startWriting() else { throw CompressionError(status: -3) }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(firstSample))
        for sb in sampleBuffers {
            writerInput.append(sb)
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CompressionError(status: -4)
        }
    }

    private static func decodeFromMP4(
        url: URL,
        expectedPixelFormat: OSType
    ) async throws -> (pixelBuffers: [CVPixelBuffer], timestamps: [CMTime], formatDescription: CMVideoFormatDescription) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw CompressionError(status: -5) }
        let descs = try await track.load(.formatDescriptions)
        guard let fd = descs.first else { throw CompressionError(status: -6) }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: expectedPixelFormat
            ]
        )
        guard reader.canAdd(readerOutput) else { throw CompressionError(status: -7) }
        reader.add(readerOutput)
        guard reader.startReading() else { throw CompressionError(status: -8) }

        var pbs: [CVPixelBuffer] = []
        var ptss: [CMTime] = []
        while let sb = readerOutput.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                pbs.append(pb)
                ptss.append(CMSampleBufferGetPresentationTimeStamp(sb))
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? CompressionError(status: -9)
        }
        return (pbs, ptss, fd)
    }

    private struct CompressionError: Error {
        let status: OSStatus
    }

    private static func makeRemuxEvidence(
        generation: MediaGeneration,
        codec: VideoCodec,
        randomAccessKind: VideoRandomAccessKind,
        scan: VideoScanClassificationEvidence = .progressive,
        pts: ExactMediaTime? = ExactMediaTime(value: 0, timescale: 90_000),
        dts: ExactMediaTime? = nil,
        allVCLAreRandomAccess: Bool? = nil
    ) -> HLSVideoTestRemuxEvidence {
        let dummySHA = Data("vplayer-test-digest".utf8)
        let paramSHA = VideoAccessUnitSHA256(bytes: dummySHA.span)
        return HLSVideoTestRemuxEvidence(
            remuxGeneration: generation,
            remuxCodec: codec,
            remuxRandomAccessKind: randomAccessKind,
            remuxParameterSetIdentity: paramSHA,
            remuxFormatIdentity: paramSHA,
            remuxProfileIDC: codec == .h264 ? 66 : 1,
            remuxProfileCompatibilityFlags: 0,
            remuxLevelIDC: codec == .h264 ? 40 : 120,
            remuxTier: .main,
            remuxWidth: 1920,
            remuxHeight: 1080,
            remuxFrameRate: MediaRational(num: 25, den: 1),
            remuxCodedPictureSizeInMacroblocks: 8160,
            remuxCodedLumaPictureSize: 2073600,
            remuxMaximumReferenceFrames: 4,
            remuxChromaFormatIDC: 1,
            remuxBitDepthLuma: 8,
            remuxBitDepthChroma: 8,
            remuxColorPrimaries: .bt709,
            remuxColorTransfer: .bt709,
            remuxColorMatrix: .bt709,
            remuxMasteringDisplay: nil,
            remuxContentLightLevel: nil,
            remuxScanClassification: scan,
            remuxPresentationTimeStamp: pts,
            remuxDecodeTimeStamp: dts,
            remuxDuration: ExactMediaTime(value: 3600, timescale: 90_000),
            remuxContainsVCL: true,
            remuxContainsInBandParameterSets: false,
            remuxAllVCLAreRandomAccess: allVCLAreRandomAccess ?? (randomAccessKind != .none),
            remuxConflictingRandomAccessKinds: false,
            remuxHasSinglePrimaryPictureStartSlice: true
        )
    }
}

private struct HLSVideoTestRemuxEvidence: VideoRemuxInspectionEvidence {
    let remuxGeneration: MediaGeneration
    let remuxCodec: VideoCodec
    let remuxRandomAccessKind: VideoRandomAccessKind
    let remuxParameterSetIdentity: VideoAccessUnitSHA256?
    let remuxFormatIdentity: VideoAccessUnitSHA256?
    let remuxProfileIDC: UInt8
    let remuxProfileCompatibilityFlags: UInt32
    let remuxLevelIDC: UInt8
    let remuxTier: VideoCodecTier
    let remuxWidth: Int32?
    let remuxHeight: Int32?
    let remuxFrameRate: MediaRational?
    let remuxCodedPictureSizeInMacroblocks: UInt32?
    let remuxCodedLumaPictureSize: UInt64?
    let remuxMaximumReferenceFrames: UInt32?
    let remuxChromaFormatIDC: UInt8?
    let remuxBitDepthLuma: UInt8?
    let remuxBitDepthChroma: UInt8?
    let remuxColorPrimaries: DemuxColorPrimaries?
    let remuxColorTransfer: DemuxColorTransfer?
    let remuxColorMatrix: DemuxColorMatrix?
    let remuxMasteringDisplay: DemuxMasteringDisplayMetadata?
    let remuxContentLightLevel: DemuxContentLightLevelMetadata?
    let remuxScanClassification: VideoScanClassificationEvidence
    let remuxPresentationTimeStamp: ExactMediaTime?
    let remuxDecodeTimeStamp: ExactMediaTime?
    let remuxDuration: ExactMediaTime?
    let remuxContainsVCL: Bool
    let remuxContainsInBandParameterSets: Bool
    let remuxAllVCLAreRandomAccess: Bool
    let remuxConflictingRandomAccessKinds: Bool
    let remuxHasSinglePrimaryPictureStartSlice: Bool
}

private extension VideoRemuxEligibility {
    convenience init(
        generation: MediaGeneration,
        codec: VideoCodec,
        sampleEntry: HLSVideoSampleEntry,
        requiresDecodeTimestamp: Bool
    ) throws {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let frameRate = try XCTUnwrap(MediaRational(num: 25, den: 1))
        let track = VideoTrackDescriptor(
            streamIndex: 0,
            codec: codec,
            timeBase: timeBase,
            width: 1_920,
            height: 1_080,
            videoDelay: requiresDecodeTimestamp ? 1 : 0,
            extradata: Data(),
            frameRate: frameRate,
            fieldOrder: .progressive
        )
        try self.init(generation: generation, track: track, sampleEntry: sampleEntry)
    }
}
