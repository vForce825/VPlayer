// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import VideoToolbox

struct AppleTemporalConfigurator {
    private let api: any VTSessionPropertyAPI

    init(api: any VTSessionPropertyAPI) {
        self.api = api
    }

    func configure(session: any VideoToolboxSession) throws {
        let snapshot = api.copySupportedPropertySnapshot(session)
        guard snapshot.status == noErr else {
            throw AppleTemporalFailure.initializationFailed(status: snapshot.status)
        }
        guard let supportedKeys = snapshot.supportedPropertyKeys else {
            throw AppleTemporalFailure.initializationFailed(status: kVTParameterErr)
        }

        let fieldModeKey = kVTDecompressionPropertyKey_FieldMode as String
        let deinterlaceModeKey = kVTDecompressionPropertyKey_DeinterlaceMode as String
        for key in [fieldModeKey, deinterlaceModeKey] where !supportedKeys.contains(key) {
            throw AppleTemporalFailure.unsupportedProperty(key)
        }

        try set(
            session: session,
            key: fieldModeKey,
            value: .string(kVTDecompressionProperty_FieldMode_DeinterlaceFields as String)
        )
        try set(
            session: session,
            key: deinterlaceModeKey,
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
    }
}
