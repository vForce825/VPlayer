// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import VideoToolbox

struct AppleTemporalConfigurator {
    /// The one property the route cannot do without: it is what makes the
    /// decoder deinterlace at all.
    static let requiredPropertyKey = kVTDecompressionPropertyKey_FieldMode as String
    /// Which algorithm the decoder deinterlaces with, and *optional* — the SDK
    /// says a decoder that does not implement it simply picks its own, and the
    /// temporal algorithm is asked for per frame through
    /// `kVTDecodeFrame_EnableTemporalProcessing` regardless.
    ///
    /// Requiring it rejected every decoder Apple currently ships: none of them
    /// implement it, including the ones that do implement `FieldMode`. That
    /// turned "this decoder deinterlaces, just not with the algorithm you asked
    /// for" into "Apple Temporal is unavailable".
    static let optionalPropertyKey = kVTDecompressionPropertyKey_DeinterlaceMode as String

    /// Whether a decoder that reports these keys can run the route at all.
    static func supportsDeinterlaceFields(_ supportedKeys: Set<String>) -> Bool {
        supportedKeys.contains(requiredPropertyKey)
    }

    private let api: any VTSessionPropertyAPI
    private let propertyDidSet: @Sendable () -> Void

    init(
        api: any VTSessionPropertyAPI,
        propertyDidSet: @escaping @Sendable () -> Void = {}
    ) {
        self.api = api
        self.propertyDidSet = propertyDidSet
    }

    func configure(session: any VideoToolboxSession) throws {
        let snapshot = api.copySupportedPropertySnapshot(session)
        guard snapshot.status == noErr else {
            throw AppleTemporalFailure.initializationFailed(status: snapshot.status)
        }
        guard let supportedKeys = snapshot.supportedPropertyKeys else {
            throw AppleTemporalFailure.initializationFailed(status: kVTParameterErr)
        }
        guard Self.supportsDeinterlaceFields(supportedKeys) else {
            throw AppleTemporalFailure.unsupportedProperty(Self.requiredPropertyKey)
        }

        try set(
            session: session,
            key: Self.requiredPropertyKey,
            value: .string(kVTDecompressionProperty_FieldMode_DeinterlaceFields as String)
        )
        guard supportedKeys.contains(Self.optionalPropertyKey) else { return }
        try set(
            session: session,
            key: Self.optionalPropertyKey,
            value: .string(kVTDecompressionProperty_DeinterlaceMode_Temporal as String)
        )
    }

    private func set(
        session: any VideoToolboxSession,
        key: String,
        value: VTPropertyValue
    ) throws {
        let status = api.setProperty(session, key: key, value: value)
        guard status == noErr else {
            throw AppleTemporalFailure.propertySetFailed(key: key, status: status)
        }
        propertyDidSet()
    }
}
