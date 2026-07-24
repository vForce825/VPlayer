// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerCore

@MainActor
final class VPlayerModelContainerTests: XCTestCase {
    func testPersistentContainerReopensWithoutQuarantiningHealthyData() async throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }

        do {
            let container = try VPlayerModelContainer.make(
                persistentStoreURL: fixture.storeURL,
                recoveryRootURL: fixture.recoveryRootURL
            )
            let store = SwiftDataLibraryStore(modelContainer: container)
            _ = try await store.createProfile(profileInput(name: "Healthy"), now: Date(timeIntervalSince1970: 1))
        }

        let reopened = try VPlayerModelContainer.make(
            persistentStoreURL: fixture.storeURL,
            recoveryRootURL: fixture.recoveryRootURL
        )
        let profiles = try await SwiftDataLibraryStore(modelContainer: reopened).profiles()

        XCTAssertEqual(profiles.map(\.name), ["Healthy"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveryRootURL.path))
    }

    func testCorruptPersistentStoreIsQuarantinedBeforeRecreation() async throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        let originalComponents: [URL: Data] = [
            fixture.storeURL: Data("corrupt-store".utf8),
            URL(fileURLWithPath: fixture.storeURL.path + "-wal"): Data("corrupt-wal".utf8),
            URL(fileURLWithPath: fixture.storeURL.path + "-shm"): Data("corrupt-shm".utf8),
            URL(fileURLWithPath: fixture.storeURL.path + "-journal"): Data("corrupt-journal".utf8),
        ]
        for (url, data) in originalComponents {
            try data.write(to: url)
        }
        let supportURL = URL(fileURLWithPath: fixture.storeURL.path + "_SUPPORT", isDirectory: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let supportPayloadURL = supportURL.appendingPathComponent("payload")
        let supportPayload = Data("corrupt-support".utf8)
        try supportPayload.write(to: supportPayloadURL)

        let recovered = try VPlayerModelContainer.make(
            persistentStoreURL: fixture.storeURL,
            recoveryRootURL: fixture.recoveryRootURL
        )
        let store = SwiftDataLibraryStore(modelContainer: recovered)
        let initiallyRecoveredProfiles = try await store.profiles()
        XCTAssertTrue(initiallyRecoveredProfiles.isEmpty)
        _ = try await store.createProfile(profileInput(name: "Recovered"), now: Date(timeIntervalSince1970: 2))
        let profilesAfterCreate = try await store.profiles()
        XCTAssertEqual(profilesAfterCreate.map(\.name), ["Recovered"])

        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.recoveryRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveryDirectories.count, 1)
        let recoveryDirectory = try XCTUnwrap(recoveryDirectories.first)
        let quarantinedStoreURL = recoveryDirectory.appendingPathComponent(fixture.storeURL.lastPathComponent)
        XCTAssertFalse(try Data(contentsOf: quarantinedStoreURL).isEmpty)
        for suffix in ["-wal", "-shm", "-journal"] {
            let quarantined = recoveryDirectory.appendingPathComponent(fixture.storeURL.lastPathComponent + suffix)
            if FileManager.default.fileExists(atPath: quarantined.path) {
                XCTAssertFalse(try Data(contentsOf: quarantined).isEmpty)
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: recoveryDirectory
                .appendingPathComponent(supportURL.lastPathComponent)
                .appendingPathComponent(supportPayloadURL.lastPathComponent)),
            supportPayload
        )
        XCTAssertNotEqual(
            try Data(contentsOf: fixture.storeURL),
            try Data(contentsOf: quarantinedStoreURL)
        )
    }

    func testFailedQuarantineRollbackPreservesMovedComponentInRecoveryDirectory() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let walURL = URL(fileURLWithPath: fixture.storeURL.path + "-wal")
        let storePayload = Data("store-that-must-survive".utf8)
        let walPayload = Data("wal-that-stays-in-place".utf8)
        try storePayload.write(to: fixture.storeURL)
        try walPayload.write(to: walURL)
        var forwardMoveCount = 0

        XCTAssertThrowsError(
            try VPlayerModelContainer.quarantine(
                [fixture.storeURL, walURL],
                recoveryRootURL: fixture.recoveryRootURL,
                fileManager: fileManager,
                moveItem: { source, destination in
                    if source.path.hasPrefix(fixture.recoveryRootURL.path + "/") {
                        throw InjectedMoveFailure.rollback
                    }
                    forwardMoveCount += 1
                    if forwardMoveCount == 2 {
                        throw InjectedMoveFailure.forward
                    }
                    try fileManager.moveItem(at: source, to: destination)
                }
            )
        )

        XCTAssertFalse(fileManager.fileExists(atPath: fixture.storeURL.path))
        XCTAssertEqual(try Data(contentsOf: walURL), walPayload)
        let recoveryDirectories = try fileManager.contentsOfDirectory(
            at: fixture.recoveryRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveryDirectories.count, 1)
        let recoveryDirectory = try XCTUnwrap(recoveryDirectories.first)
        XCTAssertEqual(
            try Data(contentsOf: recoveryDirectory.appendingPathComponent(fixture.storeURL.lastPathComponent)),
            storePayload
        )
    }

    func testPersistentStoreRootAvoidsSandboxRestrictedApplicationSupport() throws {
        // On device tvOS denies creating Library/Application Support while the
        // simulator permits it, so only a path assertion catches a regression
        // back to a location that fails solely on real hardware.
        let root = try VPlayerModelContainer.persistentStoreRootURL().standardizedFileURL
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).standardizedFileURL
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).standardizedFileURL

        XCTAssertEqual(root.path, caches.path)
        XCTAssertFalse(root.path.hasPrefix(applicationSupport.path))
    }

    private func profileInput(name: String) throws -> ValidatedSourceProfileInput {
        try SourceProfileInput(
            name: name,
            m3uURLString: "https://example.test/list.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .sixHours,
            epgRefreshInterval: .daily
        ).validated()
    }
}

private enum InjectedMoveFailure: Error {
    case forward
    case rollback
}

private final class PersistentStoreFixture {
    let directoryURL: URL
    let storeURL: URL
    let recoveryRootURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPlayerModelContainerTests-\(UUID().uuidString)", isDirectory: true)
        storeURL = directoryURL.appendingPathComponent("VPlayer.store")
        recoveryRootURL = directoryURL.appendingPathComponent("StoreRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
