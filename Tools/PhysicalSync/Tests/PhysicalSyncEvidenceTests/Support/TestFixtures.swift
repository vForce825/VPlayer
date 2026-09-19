// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation
@testable import PhysicalSyncEvidence

enum TestFixtures {
    static let zeroDigest32 = try! ExactDigest32(Data(repeating: 0, count: 32))
    static let sampleChallenge = try! ExactDigest32(Data(repeating: 0x42, count: 32))
    static let sampleCapabilityDigest = try! ExactDigest32(Data(repeating: 0x55, count: 32))
    static let samplePrivacyMaskManifestDigest = try! ExactDigest32(Data(repeating: 0x66, count: 32))
    static let sampleAppCommitDigest = try! ExactDigest32(Data(repeating: 0x77, count: 32))
    static let sampleFixtureManifestDigest = try! ExactDigest32(Data(repeating: 0x88, count: 32))

    static func makeTestReceipt(
        soundCheck: SoundCheckSettingV1 = .disabled,
        reduceBass: ReduceBassSettingV1 = .disabled,
        spatialAudio: SpatialAudioSettingV1 = .disabled,
        reduceLoudSounds: ReduceLoudSoundsSettingV1 = .disabled,
        enhanceDialogue: EnhanceDialogueSettingV1 = .disabled,
        wirelessAudioSync: WirelessAudioSyncSettingV1 = .notCalibrated,
        volume: Float = 0.5
    ) -> HomePodOutputConfigurationReceiptV2 {
        let samples = Array(repeating: volume, count: 38)
        return try! HomePodOutputConfigurationReceiptV2(
            volumeSamples: samples,
            soundCheck: soundCheck,
            reduceBass: reduceBass,
            spatialAudio: spatialAudio,
            reduceLoudSounds: reduceLoudSounds,
            enhanceDialogue: enhanceDialogue,
            wirelessAudioSync: wirelessAudioSync,
            settingsEvidenceDigest: zeroDigest32,
            capabilityManifestDigest: sampleCapabilityDigest
        )
    }

    static func makeTestEnvironmentIdentity() -> PhysicalSyncEnvironmentIdentityV1 {
        let atv = try! AppleTVIdentity(modelCode: 141, tvOSBuild: "21K100".data(using: .ascii)!)
        let hp1 = try! HomePodMember(modelCode: 201, audioOSBuild: "21K100".data(using: .ascii)!, roleCode: 1, x: 1000, y: 1200, z: 800)
        let hp2 = try! HomePodMember(modelCode: 201, audioOSBuild: "21K100".data(using: .ascii)!, roleCode: 2, x: 2000, y: 1200, z: 800)
        let topology = try! HomePodsTopology(topologyCode: 2, members: [hp1, hp2])
        let tv = TelevisionIdentity(modelCode: 55, displayModeCode: 1, hdrCode: 2, motionCode: 0, lowLatencyCode: 1)
        let captureHw = try! CaptureHardwareIdentity(
            captureDeviceCode: 1,
            cameraCode: 10,
            cameraFirmwareBytes: "CAM1.0".data(using: .ascii)!,
            microphoneCode: 20,
            audioInterfaceCode: 30,
            audioInterfaceFirmwareBytes: "AUD1.0".data(using: .ascii)!
        )
        let vidCap = try! VideoCaptureIdentity(
            width: 1920,
            height: 1080,
            rateNumerator: 240,
            rateDenominator: 1,
            exposureModeCode: 1,
            exposureNanoseconds: 4166666,
            rollingShutterDirectionCode: 0
        )
        let audCap = AudioCaptureIdentity(
            sampleRate: 48000,
            channelCount: 1,
            pcmFormatCode: 1,
            monoInputMapCode: 1,
            inputModeCode: 1,
            impedanceMilliOhm: 600,
            gainMilliDecibel: 0,
            clockCode: 1,
            dspBitset: 0
        )
        let calibrator = try! CalibratorIdentity(
            hardwareCode: 1,
            firmwareBytes: "CAL1.0".data(using: .ascii)!,
            manifestDigest: zeroDigest32
        )
        let geometry = GeometryIdentity(
            tvROICenter: Coordinate3D(x: 1500, y: 1500, z: 1000),
            calibrationLED: Coordinate3D(x: 1500, y: 1500, z: 1000),
            calibrationEmitter: Coordinate3D(x: 1500, y: 1500, z: 1000),
            microphone: Coordinate3D(x: 1500, y: 3500, z: 1000),
            orderedHomePodCenters: [
                HomePodCenter(roleCode: 1, x: 1000, y: 1200, z: 800),
                HomePodCenter(roleCode: 2, x: 2000, y: 1200, z: 800)
            ],
            calibrationEmitterToMicrophoneDistanceMM: 2000,
            orderedHomePodToMicrophoneDistancesMM: [2300, 2300],
            coordinateToleranceMM: 5,
            distanceToleranceMM: 5
        )
        let climate = ClimateIdentity(temperatureMilliCelsius: 22000, humidityPartsPerMillion: 500000, soundSpeedFormulaVersion: 1)

        return try! PhysicalSyncEnvironmentIdentityV1(
            capabilityManifestDigest: sampleCapabilityDigest,
            localeManifestCode: 1,
            appCommitDigest: sampleAppCommitDigest,
            appleTV: atv,
            homePods: topology,
            television: tv,
            captureHardware: captureHw,
            videoCapture: vidCap,
            audioCapture: audCap,
            calibrator: calibrator,
            geometry: geometry,
            climate: climate,
            fixtureManifestDigest: sampleFixtureManifestDigest
        )
    }

    static func makeTestPrivacyManifest() -> PrivacyMaskManifestV1 {
        let profile0: [SafeROI] = [
            SafeROI(x: 100, y: 50, width: 200, height: 100),
            SafeROI(x: 400, y: 50, width: 150, height: 80)
        ]
        return PrivacyMaskManifestV1(
            sourceCropWidth: 1920,
            sourceCropHeight: 1080,
            allowedProfiles: [1: profile0]
        )
    }
}
