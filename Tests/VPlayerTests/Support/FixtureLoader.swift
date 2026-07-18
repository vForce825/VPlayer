// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum FixtureLoader {
    static func data(_ relativePath: String, file: StaticString = #filePath) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let parts = relativePath.split(separator: "/").map(String.init)
        let filename = parts.last!
        let directory = parts.dropLast().joined(separator: "/")
        guard let url = bundle.url(forResource: filename, withExtension: nil, subdirectory: directory) else {
            throw NSError(domain: "FixtureLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: relativePath])
        }
        return try Data(contentsOf: url)
    }
}

private final class BundleToken {}
