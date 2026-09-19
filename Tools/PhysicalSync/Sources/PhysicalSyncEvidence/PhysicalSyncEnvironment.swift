// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum SoundCheckSettingV1: UInt8, Sendable, CaseIterable {
    case disabled = 0
    case enabled = 1
    case unsupported = 255
}

public enum ReduceBassSettingV1: UInt8, Sendable, CaseIterable {
    case disabled = 0
    case enabled = 1
    case unsupported = 255
}

public enum ReduceLoudSoundsSettingV1: UInt8, Sendable, CaseIterable {
    case disabled = 0
    case enabled = 1
    case unsupported = 255
}

public enum SpatialAudioSettingV1: UInt8, Sendable, CaseIterable {
    case disabled = 0
    case fixed = 1
    case headTracked = 2
    case automatic = 3
    case unsupported = 255
}

public enum EnhanceDialogueSettingV1: UInt8, Sendable, CaseIterable {
    case disabled = 0
    case enhance = 1
    case boost = 2
    case unsupported = 255
}

public enum WirelessAudioSyncSettingV1: UInt8, Sendable, CaseIterable {
    case notCalibrated = 0
    case calibrated = 1
    case unsupported = 255
}

public enum EnvironmentError: Error, Equatable, Sendable {
    case invalidVolumeSampleCount(Int)
    case nonFiniteOrOutOfRangeVolumeSample
    case nonIdenticalVolumeSamples
    case invalidMemberCount(Int)
    case geometryMemberMismatch
    case stringExceedsMaxBytes
    case invalidRateDenominator
}

public struct HomePodOutputConfigurationReceiptV2: Equatable, Sendable {
    public let schemaVersion: UInt8 = 2
    public let volumeSourceCode: UInt8 = 1
    public let volumeScalarBitPattern: UInt32
    public let volumeSampleCount: UInt32 = 38
    public let soundCheck: SoundCheckSettingV1
    public let reduceBass: ReduceBassSettingV1
    public let spatialAudio: SpatialAudioSettingV1
    public let reduceLoudSounds: ReduceLoudSoundsSettingV1
    public let enhanceDialogue: EnhanceDialogueSettingV1
    public let wirelessAudioSync: WirelessAudioSyncSettingV1
    public let settingsEvidenceMethodCode: UInt8 = 1
    public let settingsEvidenceDigest: ExactDigest32
    public let capabilityManifestDigest: ExactDigest32

    public init(
        volumeSamples: [Float],
        soundCheck: SoundCheckSettingV1,
        reduceBass: ReduceBassSettingV1,
        spatialAudio: SpatialAudioSettingV1,
        reduceLoudSounds: ReduceLoudSoundsSettingV1,
        enhanceDialogue: EnhanceDialogueSettingV1,
        wirelessAudioSync: WirelessAudioSyncSettingV1,
        settingsEvidenceDigest: ExactDigest32,
        capabilityManifestDigest: ExactDigest32
    ) throws {
        guard volumeSamples.count == 38 else {
            throw EnvironmentError.invalidVolumeSampleCount(volumeSamples.count)
        }

        let firstPattern = volumeSamples[0].bitPattern
        for s in volumeSamples {
            guard !s.isNaN && !s.isInfinite && s >= 0.0 && s <= 1.0 else {
                throw EnvironmentError.nonFiniteOrOutOfRangeVolumeSample
            }
            guard s.bitPattern == firstPattern else {
                throw EnvironmentError.nonIdenticalVolumeSamples
            }
        }

        self.volumeScalarBitPattern = firstPattern
        self.soundCheck = soundCheck
        self.reduceBass = reduceBass
        self.spatialAudio = spatialAudio
        self.reduceLoudSounds = reduceLoudSounds
        self.enhanceDialogue = enhanceDialogue
        self.wirelessAudioSync = wirelessAudioSync
        self.settingsEvidenceDigest = settingsEvidenceDigest
        self.capabilityManifestDigest = capabilityManifestDigest
    }

    public init(
        volumeScalarBitPattern: UInt32,
        soundCheck: SoundCheckSettingV1,
        reduceBass: ReduceBassSettingV1,
        spatialAudio: SpatialAudioSettingV1,
        reduceLoudSounds: ReduceLoudSoundsSettingV1,
        enhanceDialogue: EnhanceDialogueSettingV1,
        wirelessAudioSync: WirelessAudioSyncSettingV1,
        settingsEvidenceDigest: ExactDigest32,
        capabilityManifestDigest: ExactDigest32
    ) {
        self.volumeScalarBitPattern = volumeScalarBitPattern
        self.soundCheck = soundCheck
        self.reduceBass = reduceBass
        self.spatialAudio = spatialAudio
        self.reduceLoudSounds = reduceLoudSounds
        self.enhanceDialogue = enhanceDialogue
        self.wirelessAudioSync = wirelessAudioSync
        self.settingsEvidenceDigest = settingsEvidenceDigest
        self.capabilityManifestDigest = capabilityManifestDigest
    }

    public func toCanonicalCBOR() -> Data {
        var patternBE = volumeScalarBitPattern.bigEndian
        let patternBytes = Data(bytes: &patternBE, count: 4)

        let items: [CBORValue] = [
            .unsigned(UInt64(schemaVersion)),
            .unsigned(UInt64(volumeSourceCode)),
            .byteString(patternBytes),
            .unsigned(UInt64(volumeSampleCount)),
            .unsigned(UInt64(soundCheck.rawValue)),
            .unsigned(UInt64(reduceBass.rawValue)),
            .unsigned(UInt64(spatialAudio.rawValue)),
            .unsigned(UInt64(reduceLoudSounds.rawValue)),
            .unsigned(UInt64(enhanceDialogue.rawValue)),
            .unsigned(UInt64(wirelessAudioSync.rawValue)),
            .unsigned(UInt64(settingsEvidenceMethodCode)),
            .byteString(settingsEvidenceDigest.bytes),
            .byteString(capabilityManifestDigest.bytes)
        ]

        return try! CanonicalCBOR.encode(.array(items))
    }

    public var receiptIdentity: ExactDigest32 {
        ExactDigest32.sha256(of: toCanonicalCBOR())
    }
}

public struct AppleTVIdentity: Equatable, Sendable {
    public let modelCode: UInt32
    public let tvOSBuild: Data

    public init(modelCode: UInt32, tvOSBuild: Data) throws {
        guard !tvOSBuild.isEmpty && tvOSBuild.count <= 32 else {
            throw EnvironmentError.stringExceedsMaxBytes
        }
        self.modelCode = modelCode
        self.tvOSBuild = tvOSBuild
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(modelCode)),
            .byteString(tvOSBuild)
        ])
    }
}

public struct HomePodMember: Equatable, Sendable {
    public let modelCode: UInt32
    public let audioOSBuild: Data
    public let roleCode: UInt8
    public let x: Int64
    public let y: Int64
    public let z: Int64

    public init(modelCode: UInt32, audioOSBuild: Data, roleCode: UInt8, x: Int64, y: Int64, z: Int64) throws {
        guard !audioOSBuild.isEmpty && audioOSBuild.count <= 32 else {
            throw EnvironmentError.stringExceedsMaxBytes
        }
        self.modelCode = modelCode
        self.audioOSBuild = audioOSBuild
        self.roleCode = roleCode
        self.x = x
        self.y = y
        self.z = z
    }

    private func int64ToCBOR(_ val: Int64) -> CBORValue {
        if val >= 0 {
            return .unsigned(UInt64(val))
        } else {
            return .negative(UInt64(~val))
        }
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(modelCode)),
            .byteString(audioOSBuild),
            .unsigned(UInt64(roleCode)),
            int64ToCBOR(x),
            int64ToCBOR(y),
            int64ToCBOR(z)
        ])
    }
}

public struct HomePodsTopology: Equatable, Sendable {
    public let topologyCode: UInt8
    public let members: [HomePodMember]

    public init(topologyCode: UInt8, members: [HomePodMember]) throws {
        guard members.count >= 1 && members.count <= 2 else {
            throw EnvironmentError.invalidMemberCount(members.count)
        }
        self.topologyCode = topologyCode
        self.members = members
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(topologyCode)),
            .array(members.map { $0.toCBOR() })
        ])
    }
}

public struct TelevisionIdentity: Equatable, Sendable {
    public let modelCode: UInt32
    public let displayModeCode: UInt32
    public let hdrCode: UInt32
    public let motionCode: UInt32
    public let lowLatencyCode: UInt32

    public init(modelCode: UInt32, displayModeCode: UInt32, hdrCode: UInt32, motionCode: UInt32, lowLatencyCode: UInt32) {
        self.modelCode = modelCode
        self.displayModeCode = displayModeCode
        self.hdrCode = hdrCode
        self.motionCode = motionCode
        self.lowLatencyCode = lowLatencyCode
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(modelCode)),
            .unsigned(UInt64(displayModeCode)),
            .unsigned(UInt64(hdrCode)),
            .unsigned(UInt64(motionCode)),
            .unsigned(UInt64(lowLatencyCode))
        ])
    }
}

public struct CaptureHardwareIdentity: Equatable, Sendable {
    public let captureDeviceCode: UInt32
    public let cameraCode: UInt32
    public let cameraFirmwareBytes: Data
    public let microphoneCode: UInt32
    public let audioInterfaceCode: UInt32
    public let audioInterfaceFirmwareBytes: Data

    public init(
        captureDeviceCode: UInt32,
        cameraCode: UInt32,
        cameraFirmwareBytes: Data,
        microphoneCode: UInt32,
        audioInterfaceCode: UInt32,
        audioInterfaceFirmwareBytes: Data
    ) throws {
        guard !cameraFirmwareBytes.isEmpty && cameraFirmwareBytes.count <= 32,
              !audioInterfaceFirmwareBytes.isEmpty && audioInterfaceFirmwareBytes.count <= 32 else {
            throw EnvironmentError.stringExceedsMaxBytes
        }
        self.captureDeviceCode = captureDeviceCode
        self.cameraCode = cameraCode
        self.cameraFirmwareBytes = cameraFirmwareBytes
        self.microphoneCode = microphoneCode
        self.audioInterfaceCode = audioInterfaceCode
        self.audioInterfaceFirmwareBytes = audioInterfaceFirmwareBytes
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(captureDeviceCode)),
            .unsigned(UInt64(cameraCode)),
            .byteString(cameraFirmwareBytes),
            .unsigned(UInt64(microphoneCode)),
            .unsigned(UInt64(audioInterfaceCode)),
            .byteString(audioInterfaceFirmwareBytes)
        ])
    }
}

public struct VideoCaptureIdentity: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let rateNumerator: UInt64
    public let rateDenominator: UInt64
    public let exposureModeCode: UInt32
    public let exposureNanoseconds: UInt64
    public let rollingShutterDirectionCode: UInt32

    public init(
        width: UInt32,
        height: UInt32,
        rateNumerator: UInt64,
        rateDenominator: UInt64,
        exposureModeCode: UInt32,
        exposureNanoseconds: UInt64,
        rollingShutterDirectionCode: UInt32
    ) throws {
        guard rateDenominator > 0 else {
            throw EnvironmentError.invalidRateDenominator
        }
        self.width = width
        self.height = height
        self.rateNumerator = rateNumerator
        self.rateDenominator = rateDenominator
        self.exposureModeCode = exposureModeCode
        self.exposureNanoseconds = exposureNanoseconds
        self.rollingShutterDirectionCode = rollingShutterDirectionCode
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(width)),
            .unsigned(UInt64(height)),
            .unsigned(rateNumerator),
            .unsigned(rateDenominator),
            .unsigned(UInt64(exposureModeCode)),
            .unsigned(exposureNanoseconds),
            .unsigned(UInt64(rollingShutterDirectionCode))
        ])
    }
}

public struct AudioCaptureIdentity: Equatable, Sendable {
    public let sampleRate: UInt32
    public let channelCount: UInt32
    public let pcmFormatCode: UInt32
    public let monoInputMapCode: UInt32
    public let inputModeCode: UInt32
    public let impedanceMilliOhm: UInt32
    public let gainMilliDecibel: Int32
    public let clockCode: UInt32
    public let dspBitset: UInt32

    public init(
        sampleRate: UInt32,
        channelCount: UInt32,
        pcmFormatCode: UInt32,
        monoInputMapCode: UInt32,
        inputModeCode: UInt32,
        impedanceMilliOhm: UInt32,
        gainMilliDecibel: Int32,
        clockCode: UInt32,
        dspBitset: UInt32
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.pcmFormatCode = pcmFormatCode
        self.monoInputMapCode = monoInputMapCode
        self.inputModeCode = inputModeCode
        self.impedanceMilliOhm = impedanceMilliOhm
        self.gainMilliDecibel = gainMilliDecibel
        self.clockCode = clockCode
        self.dspBitset = dspBitset
    }

    public func toCBOR() -> CBORValue {
        let gainCBOR: CBORValue = gainMilliDecibel >= 0 ?
            .unsigned(UInt64(gainMilliDecibel)) :
            .negative(UInt64(~Int64(gainMilliDecibel)))
        return .array([
            .unsigned(UInt64(sampleRate)),
            .unsigned(UInt64(channelCount)),
            .unsigned(UInt64(pcmFormatCode)),
            .unsigned(UInt64(monoInputMapCode)),
            .unsigned(UInt64(inputModeCode)),
            .unsigned(UInt64(impedanceMilliOhm)),
            gainCBOR,
            .unsigned(UInt64(clockCode)),
            .unsigned(UInt64(dspBitset))
        ])
    }
}

public struct CalibratorIdentity: Equatable, Sendable {
    public let hardwareCode: UInt32
    public let firmwareBytes: Data
    public let manifestDigest: ExactDigest32

    public init(hardwareCode: UInt32, firmwareBytes: Data, manifestDigest: ExactDigest32) throws {
        guard !firmwareBytes.isEmpty && firmwareBytes.count <= 32 else {
            throw EnvironmentError.stringExceedsMaxBytes
        }
        self.hardwareCode = hardwareCode
        self.firmwareBytes = firmwareBytes
        self.manifestDigest = manifestDigest
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(hardwareCode)),
            .byteString(firmwareBytes),
            .byteString(manifestDigest.bytes)
        ])
    }
}

public struct Coordinate3D: Equatable, Sendable {
    public let x: Int64
    public let y: Int64
    public let z: Int64
    public init(x: Int64, y: Int64, z: Int64) {
        self.x = x
        self.y = y
        self.z = z
    }

    private func int64ToCBOR(_ val: Int64) -> CBORValue {
        if val >= 0 {
            return .unsigned(UInt64(val))
        } else {
            return .negative(UInt64(~val))
        }
    }

    public func toCBOR() -> CBORValue {
        .array([
            int64ToCBOR(x),
            int64ToCBOR(y),
            int64ToCBOR(z)
        ])
    }
}

public struct HomePodCenter: Equatable, Sendable {
    public let roleCode: UInt8
    public let x: Int64
    public let y: Int64
    public let z: Int64
    public init(roleCode: UInt8, x: Int64, y: Int64, z: Int64) {
        self.roleCode = roleCode
        self.x = x
        self.y = y
        self.z = z
    }

    private func int64ToCBOR(_ val: Int64) -> CBORValue {
        if val >= 0 {
            return .unsigned(UInt64(val))
        } else {
            return .negative(UInt64(~val))
        }
    }

    public func toCBOR() -> CBORValue {
        .array([
            .unsigned(UInt64(roleCode)),
            int64ToCBOR(x),
            int64ToCBOR(y),
            int64ToCBOR(z)
        ])
    }
}

public struct GeometryIdentity: Equatable, Sendable {
    public let tvROICenter: Coordinate3D
    public let calibrationLED: Coordinate3D
    public let calibrationEmitter: Coordinate3D
    public let microphone: Coordinate3D
    public let orderedHomePodCenters: [HomePodCenter]
    public let calibrationEmitterToMicrophoneDistanceMM: UInt64
    public let orderedHomePodToMicrophoneDistancesMM: [UInt64]
    public let coordinateToleranceMM: UInt64
    public let distanceToleranceMM: UInt64

    public init(
        tvROICenter: Coordinate3D,
        calibrationLED: Coordinate3D,
        calibrationEmitter: Coordinate3D,
        microphone: Coordinate3D,
        orderedHomePodCenters: [HomePodCenter],
        calibrationEmitterToMicrophoneDistanceMM: UInt64,
        orderedHomePodToMicrophoneDistancesMM: [UInt64],
        coordinateToleranceMM: UInt64,
        distanceToleranceMM: UInt64
    ) {
        self.tvROICenter = tvROICenter
        self.calibrationLED = calibrationLED
        self.calibrationEmitter = calibrationEmitter
        self.microphone = microphone
        self.orderedHomePodCenters = orderedHomePodCenters
        self.calibrationEmitterToMicrophoneDistanceMM = calibrationEmitterToMicrophoneDistanceMM
        self.orderedHomePodToMicrophoneDistancesMM = orderedHomePodToMicrophoneDistancesMM
        self.coordinateToleranceMM = coordinateToleranceMM
        self.distanceToleranceMM = distanceToleranceMM
    }

    public func toCBOR() -> CBORValue {
        .array([
            tvROICenter.toCBOR(),
            calibrationLED.toCBOR(),
            calibrationEmitter.toCBOR(),
            microphone.toCBOR(),
            .array(orderedHomePodCenters.map { $0.toCBOR() }),
            .unsigned(calibrationEmitterToMicrophoneDistanceMM),
            .array(orderedHomePodToMicrophoneDistancesMM.map { .unsigned($0) }),
            .unsigned(coordinateToleranceMM),
            .unsigned(distanceToleranceMM)
        ])
    }
}

public struct ClimateIdentity: Equatable, Sendable {
    public let temperatureMilliCelsius: Int64
    public let humidityPartsPerMillion: UInt64
    public let soundSpeedFormulaVersion: UInt32
    public init(temperatureMilliCelsius: Int64, humidityPartsPerMillion: UInt64, soundSpeedFormulaVersion: UInt32) {
        self.temperatureMilliCelsius = temperatureMilliCelsius
        self.humidityPartsPerMillion = humidityPartsPerMillion
        self.soundSpeedFormulaVersion = soundSpeedFormulaVersion
    }

    public func toCBOR() -> CBORValue {
        let tempCBOR: CBORValue = temperatureMilliCelsius >= 0 ?
            .unsigned(UInt64(temperatureMilliCelsius)) :
            .negative(UInt64(~temperatureMilliCelsius))
        return .array([
            tempCBOR,
            .unsigned(humidityPartsPerMillion),
            .unsigned(UInt64(soundSpeedFormulaVersion))
        ])
    }
}

public struct PhysicalSyncEnvironmentIdentityV1: Equatable, Sendable {
    public let schemaVersion: UInt32 = 1
    public let capabilityManifestDigest: ExactDigest32
    public let localeManifestCode: UInt32
    public let appCommitDigest: ExactDigest32
    public let appleTV: AppleTVIdentity
    public let homePods: HomePodsTopology
    public let television: TelevisionIdentity
    public let captureHardware: CaptureHardwareIdentity
    public let videoCapture: VideoCaptureIdentity
    public let audioCapture: AudioCaptureIdentity
    public let calibrator: CalibratorIdentity
    public let geometry: GeometryIdentity
    public let climate: ClimateIdentity
    public let fixtureManifestDigest: ExactDigest32

    public init(
        capabilityManifestDigest: ExactDigest32,
        localeManifestCode: UInt32,
        appCommitDigest: ExactDigest32,
        appleTV: AppleTVIdentity,
        homePods: HomePodsTopology,
        television: TelevisionIdentity,
        captureHardware: CaptureHardwareIdentity,
        videoCapture: VideoCaptureIdentity,
        audioCapture: AudioCaptureIdentity,
        calibrator: CalibratorIdentity,
        geometry: GeometryIdentity,
        climate: ClimateIdentity,
        fixtureManifestDigest: ExactDigest32
    ) throws {
        guard geometry.orderedHomePodCenters.count == homePods.members.count,
              geometry.orderedHomePodToMicrophoneDistancesMM.count == homePods.members.count else {
            throw EnvironmentError.geometryMemberMismatch
        }
        self.capabilityManifestDigest = capabilityManifestDigest
        self.localeManifestCode = localeManifestCode
        self.appCommitDigest = appCommitDigest
        self.appleTV = appleTV
        self.homePods = homePods
        self.television = television
        self.captureHardware = captureHardware
        self.videoCapture = videoCapture
        self.audioCapture = audioCapture
        self.calibrator = calibrator
        self.geometry = geometry
        self.climate = climate
        self.fixtureManifestDigest = fixtureManifestDigest
    }

    public func toCanonicalCBOR() -> Data {
        let items: [CBORValue] = [
            .unsigned(UInt64(schemaVersion)),
            .byteString(capabilityManifestDigest.bytes),
            .unsigned(UInt64(localeManifestCode)),
            .byteString(appCommitDigest.bytes),
            appleTV.toCBOR(),
            homePods.toCBOR(),
            television.toCBOR(),
            captureHardware.toCBOR(),
            videoCapture.toCBOR(),
            audioCapture.toCBOR(),
            calibrator.toCBOR(),
            geometry.toCBOR(),
            climate.toCBOR(),
            .byteString(fixtureManifestDigest.bytes)
        ]
        return try! CanonicalCBOR.encode(.array(items))
    }

    public var environmentIdentityDigest: ExactDigest32 {
        ExactDigest32.sha256(of: toCanonicalCBOR())
    }
}
