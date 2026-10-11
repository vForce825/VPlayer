// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import Foundation
#if !os(macOS)
import AVFAudio
#endif

/// 平台适配层使用一致的端点语义，不向共享控制队列暴露系统对象。
enum PlaybackAudioPortNames {
    #if os(macOS)
    static let airPlay = "AirPlay"
    static let HDMI = "HDMI"
    static let bluetoothA2DP = "BluetoothA2DPOutput"
    static let bluetoothLE = "BluetoothLE"
    static let bluetoothHFP = "BluetoothHFP"
    static let builtInSpeaker = "Speaker"
    static let builtInMic = "MicrophoneBuiltIn"
    #else
    static let airPlay = AVAudioSession.Port.airPlay.rawValue
    static let HDMI = AVAudioSession.Port.HDMI.rawValue
    static let bluetoothA2DP = AVAudioSession.Port.bluetoothA2DP.rawValue
    static let bluetoothLE = AVAudioSession.Port.bluetoothLE.rawValue
    static let bluetoothHFP = AVAudioSession.Port.bluetoothHFP.rawValue
    static let builtInSpeaker = AVAudioSession.Port.builtInSpeaker.rawValue
    static let builtInMic = AVAudioSession.Port.builtInMic.rawValue
    #endif
}
