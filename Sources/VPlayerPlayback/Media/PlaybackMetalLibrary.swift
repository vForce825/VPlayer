// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Metal

enum PlaybackMetalLibrary {
    private static var resourceName: String {
        #if os(iOS)
        #if targetEnvironment(simulator)
        "VPlayerPlayback-iphonesimulator"
        #else
        "VPlayerPlayback-ios"
        #endif
        #else
        #if targetEnvironment(simulator)
        "VPlayerPlayback-tvsimulator"
        #else
        "VPlayerPlayback-tvos"
        #endif
        #endif
    }

    static func makeLibrary(
        device: any MTLDevice,
        bundle: Bundle
    ) throws -> any MTLLibrary {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "metallib"
        ) else {
            throw PlaybackMetalLibraryError.resourceUnavailable(resourceName)
        }
        return try device.makeLibrary(URL: url)
    }
}

private enum PlaybackMetalLibraryError: Error {
    case resourceUnavailable(String)
}
