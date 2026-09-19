// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

enum AudioSessionActualPolicy: Sendable, Equatable { case longFormAudio, `default` }
enum PreferredAudioSessionConfigurationPlan: Sendable, Equatable {
    // 固定playback/moviePlayback；只有准确long-form失败才允许default。
    case preferredLongFormThenDefault
}
enum AudioSessionConfigurationStep: Sendable, Equatable {
    case longFormCategoryAttempt, defaultCategoryFallbackAttempt, multichannelCapability
}
struct AudioSessionFixedFailure: Sendable, Equatable {
    enum Domain: Sendable, Equatable { case audioSession, osStatus, unknown }
    let domain: Domain
    let code: Int32
}
struct AudioSessionConfigurationAttempt: Sendable, Equatable {
    let nonce: UInt64
    let plan: PreferredAudioSessionConfigurationPlan
    let mediaServicesEpoch: UInt64
}
enum AudioSessionConfigurationProgress: Sendable, Equatable {
    case awaitingLongForm
    case awaitingFallback(preferredFailure: AudioSessionFixedFailure)
    case awaitingMultichannel(actualPolicy: AudioSessionActualPolicy, preferredFailure: AudioSessionFixedFailure?)
    case complete(actualPolicy: AudioSessionActualPolicy, preferredFailure: AudioSessionFixedFailure?, multichannel: Bool)
    case failed(AudioSessionFixedFailure)
}
enum AudioSessionConfigurationCallResult: Sendable, Equatable {
    case categorySucceeded
    case multichannelCapability(Bool)
    case failed(AudioSessionFixedFailure)
}
