// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum FixtureLoader {
    static func url(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let filename = parts.last else {
            throw NSError(domain: "FixtureLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: relativePath])
        }
        let directory = parts.dropLast().joined(separator: "/")
        if let bundleURL = bundle.url(forResource: filename, withExtension: nil, subdirectory: directory.isEmpty ? nil : directory) {
            return bundleURL
        }
        let thisFile = URL(fileURLWithPath: "\(file)")
        let mediaDir = thisFile.deletingLastPathComponent().deletingLastPathComponent().appending(component: "Fixtures").appending(component: "Media")
        let sourceURL = mediaDir.appending(path: relativePath)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        throw NSError(domain: "FixtureLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(relativePath)"])
    }

    static func data(_ relativePath: String, file: StaticString = #filePath) throws -> Data {
        let u = try url(relativePath, file: file)
        return try Data(contentsOf: u)
    }
}

private final class BundleToken {}
