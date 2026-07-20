// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import VideoToolbox

public final class VideoToolboxDecoder: VideoDecoding, @unchecked Sendable {
    private struct ActiveSession {
        let session: any VideoToolboxSession
        let id: VTSessionID
        let generation: MediaGeneration
        let configuration: VideoDecodeConfiguration
    }

    private struct DecodeToken: @unchecked Sendable {
        let accessUnitID: UInt64
        let generation: MediaGeneration
        let parserMetadata: VideoParserMetadata
    }

    private struct ClassifiedFailure {
        let failure: VideoDecoderFailure
        let isRecoverable: Bool
    }

    private let executor: PlaybackSerialExecutor
    private let eventSink: @Sendable (VideoDecoderEvent) -> Void
    private let api: any VideoToolboxAPI
    private let compatibilityCheck: PixelBufferCompatibilityCheck
    private var active: ActiveSession?

    public convenience init(
        executor: PlaybackSerialExecutor,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void
    ) {
        self.init(
            executor: executor,
            eventSink: eventSink,
            api: SystemVideoToolboxAPI(),
            compatibilityCheck: VideoFormatMetadataReader.systemCompatibilityCheck
        )
    }

    init(
        executor: PlaybackSerialExecutor,
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void,
        api: any VideoToolboxAPI,
        compatibilityCheck: @escaping PixelBufferCompatibilityCheck = VideoFormatMetadataReader.systemCompatibilityCheck
    ) {
        self.executor = executor
        self.eventSink = eventSink
        self.api = api
        self.compatibilityCheck = compatibilityCheck
    }

    public func configure(
        format: CMVideoFormatDescription,
        generation: MediaGeneration,
        configuration: VideoDecodeConfiguration
    ) throws {
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        guard subtype == kCMVideoCodecType_H264 || subtype == kCMVideoCodecType_HEVC else {
            throw VideoDecoderFailure.sessionCreate(kVTVideoDecoderUnsupportedDataFormatErr)
        }

        let decoderSpecification: [String: VTPropertyValue] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: .boolean(true),
        ]
        let imageBufferAttributes: [String: VTPropertyValue] = [
            kCVPixelBufferMetalCompatibilityKey as String: .boolean(true),
            kCVPixelBufferIOSurfacePropertiesKey as String: .dictionary([:]),
            kCVPixelBufferPixelFormatTypeKey as String: .array([
                .unsigned32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                .unsigned32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                .unsigned32(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            ]),
        ]
        let creation = api.createSession(
            format: format,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: imageBufferAttributes
        )
        guard creation.status == noErr, let candidate = creation.session else {
            if let candidate = creation.session { api.invalidate(candidate) }
            throw VideoDecoderFailure.sessionCreate(creation.status)
        }

        switch configuration {
        case .bothFields:
            let setStatus = api.setProperty(
                candidate,
                key: kVTDecompressionPropertyKey_FieldMode as String,
                value: .string(kVTDecompressionProperty_FieldMode_BothFields as String)
            )
            guard setStatus == noErr else {
                api.invalidate(candidate)
                throw VideoDecoderFailure.sessionCreate(setStatus)
            }
        case .appleTemporal:
            do {
                try AppleTemporalConfigurator(api: api).configure(session: candidate)
            } catch let failure as AppleTemporalFailure {
                api.invalidate(candidate)
                throw VideoDecoderFailure.temporalUnavailable(failure)
            } catch {
                api.invalidate(candidate)
                throw VideoDecoderFailure.temporalUnavailable(
                    .initializationFailed(status: kVTParameterErr)
                )
            }
        }

        let hardware = api.copyProperty(
            candidate,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder as String
        )
        guard hardware.status == noErr else {
            api.invalidate(candidate)
            throw VideoDecoderFailure.sessionCreate(hardware.status)
        }
        guard hardware.value == .boolean(true) else {
            api.invalidate(candidate)
            throw VideoDecoderFailure.softwareDecoder
        }

        let previous = active
        active = ActiveSession(
            session: candidate,
            id: candidate.id,
            generation: generation,
            configuration: configuration
        )
        if let previous { api.invalidate(previous.session) }
    }

    public func decode(
        _ accessUnit: CompressedVideoAccessUnit,
        flags: VTDecodeFrameFlags
    ) throws {
        guard let active, accessUnit.generation == active.generation else { return }
        let token = DecodeToken(
            accessUnitID: accessUnit.id,
            generation: accessUnit.generation,
            parserMetadata: accessUnit.parserMetadata
        )
        let sessionID = active.id
        let executor = executor
        var decodeFlags = flags
        decodeFlags.insert(._EnableAsynchronousDecompression)
        switch active.configuration {
        case .bothFields:
            decodeFlags.remove(._EnableTemporalProcessing)
        case .appleTemporal:
            decodeFlags.insert(._EnableTemporalProcessing)
        }
        let status = api.decode(
            active.session,
            sampleBuffer: accessUnit.sampleBuffer,
            flags: decodeFlags,
            frameOptions: nil
        ) { [weak self] output in
            executor.submit { [weak self] in
                self?.handle(output: output, token: token, sessionID: sessionID)
            }
        }
        guard status == noErr else {
            throw Self.classify(status, configuration: active.configuration).failure
        }
    }

    public func finishDelayedFrames() throws {
        guard let active else { return }
        let status = api.finishDelayedFrames(active.session)
        guard status == noErr else {
            throw Self.classify(status, configuration: active.configuration).failure
        }
    }

    public func waitForAsynchronousFrames() throws {
        guard let active else { return }
        let status = api.waitForAsynchronousFrames(active.session)
        guard status == noErr else {
            throw Self.classify(status, configuration: active.configuration).failure
        }
    }

    public func invalidate() {
        guard let current = active else { return }
        active = nil
        api.invalidate(current.session)
    }

    private func handle(
        output: VTDecodeOutput,
        token: DecodeToken,
        sessionID: VTSessionID
    ) {
        guard let active,
              active.id == sessionID,
              active.generation == token.generation else {
            return
        }

        guard output.status == noErr else {
            emit(
                Self.classify(output.status, configuration: active.configuration),
                generation: token.generation
            )
            return
        }
        guard let pixelBuffer = output.imageBuffer else {
            if output.infoFlags.contains(.frameDropped)
                || output.infoFlags.contains(.frameInterrupted) {
                return
            }
            emit(
                Self.classify(
                    kVTVideoDecoderMalfunctionErr,
                    configuration: active.configuration
                ),
                generation: token.generation
            )
            return
        }

        do {
            let formatMetadata = try VideoFormatMetadataReader.read(
                from: pixelBuffer,
                compatibilityCheck: compatibilityCheck
            )
            eventSink(.frame(DecodedVideoFrame(
                accessUnitID: token.accessUnitID,
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: output.presentationTimeStamp,
                duration: output.duration,
                generation: token.generation,
                parserMetadata: token.parserMetadata,
                formatMetadata: formatMetadata
            )))
        } catch let failure as VideoDecoderFailure {
            emit(
                ClassifiedFailure(failure: failure, isRecoverable: false),
                generation: token.generation
            )
        } catch {
            emit(
                ClassifiedFailure(
                    failure: .malfunction(kVTVideoDecoderMalfunctionErr),
                    isRecoverable: false
                ),
                generation: token.generation
            )
        }
    }

    private func emit(_ classified: ClassifiedFailure, generation: MediaGeneration) {
        if classified.isRecoverable {
            eventSink(.recoverableFailure(classified.failure, generation: generation))
        } else {
            eventSink(.fatalFailure(classified.failure, generation: generation))
        }
    }

    private static func classify(
        _ status: OSStatus,
        configuration: VideoDecodeConfiguration
    ) -> ClassifiedFailure {
        if configuration == .appleTemporal {
            switch status {
            case kVTVideoDecoderBadDataErr, kVTVideoDecoderReferenceMissingErr:
                return ClassifiedFailure(failure: .badData(status), isRecoverable: true)
            case kVTVideoDecoderUnsupportedDataFormatErr:
                return ClassifiedFailure(failure: .badData(status), isRecoverable: false)
            default:
                return ClassifiedFailure(
                    failure: .temporalUnavailable(.processingFailed(status: status)),
                    isRecoverable: true
                )
            }
        }

        switch status {
        case kVTVideoDecoderBadDataErr, kVTVideoDecoderReferenceMissingErr:
            return ClassifiedFailure(failure: .badData(status), isRecoverable: true)
        case kVTVideoDecoderUnsupportedDataFormatErr:
            return ClassifiedFailure(failure: .badData(status), isRecoverable: false)
        case kVTVideoDecoderMalfunctionErr,
             kVTSessionMalfunctionErr,
             kVTVideoDecoderNotAvailableNowErr,
             kVTVideoDecoderRemovedErr:
            return ClassifiedFailure(failure: .malfunction(status), isRecoverable: true)
        default:
            return ClassifiedFailure(failure: .malfunction(status), isRecoverable: false)
        }
    }
}
