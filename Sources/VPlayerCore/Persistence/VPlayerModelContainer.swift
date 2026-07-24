// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftData

public enum VPlayerModelContainer {
    public static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = makeSchema()
        if inMemory {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [configuration])
        }

        let storeRoot = try persistentStoreRootURL()
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: true
        )
        return try make(
            persistentStoreURL: storeRoot.appendingPathComponent("VPlayer.store"),
            recoveryRootURL: storeRoot.appendingPathComponent(
                "VPlayerStoreRecovery",
                isDirectory: true
            )
        )
    }

    static func make(
        persistentStoreURL: URL,
        recoveryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> ModelContainer {
        try fileManager.createDirectory(
            at: persistentStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            return try makePersistentContainer(at: persistentStoreURL)
        } catch {
            do {
                return try makePersistentContainer(at: persistentStoreURL)
            } catch {
                let components = persistentStoreComponents(
                    at: persistentStoreURL,
                    fileManager: fileManager
                )
                guard !components.isEmpty else { throw error }
                try quarantine(
                    components,
                    recoveryRootURL: recoveryRootURL,
                    fileManager: fileManager
                )
                return try makePersistentContainer(at: persistentStoreURL)
            }
        }
    }

    /// tvOS only grants the sandbox write access to Caches and tmp. Creating
    /// `Library/Application Support` fails on device with EPERM even though the
    /// simulator allows it, so Caches is the only usable store location here.
    /// The library is a rebuildable mirror of the remote playlist and EPG, so a
    /// system purge under storage pressure costs a refresh, not user data.
    static func persistentStoreRootURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private static func makeSchema() -> Schema {
        Schema([
            LibraryStateRecord.self,
            SourceProfileRecord.self,
            PlaylistSnapshotRecord.self,
            ChannelRecord.self,
            EPGSnapshotRecord.self,
            EPGChannelRecord.self,
            ProgrammeRecord.self,
            ManualEPGMappingRecord.self
        ])
    }

    private static func makePersistentContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = makeSchema()
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func persistentStoreComponents(
        at storeURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let paths = [
            storeURL.path,
            storeURL.path + "-wal",
            storeURL.path + "-shm",
            storeURL.path + "-journal",
            storeURL.path + "_SUPPORT",
        ]
        return paths
            .map(URL.init(fileURLWithPath:))
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    static func quarantine(
        _ components: [URL],
        recoveryRootURL: URL,
        fileManager: FileManager,
        moveItem injectedMoveItem: ((URL, URL) throws -> Void)? = nil
    ) throws {
        let moveItem = injectedMoveItem ?? { source, destination in
            try fileManager.moveItem(at: source, to: destination)
        }
        let recoveryDirectory = recoveryRootURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        var moved: [(original: URL, quarantined: URL)] = []
        do {
            for component in components {
                let destination = recoveryDirectory.appendingPathComponent(
                    component.lastPathComponent,
                    isDirectory: component.hasDirectoryPath
                )
                try moveItem(component, destination)
                moved.append((component, destination))
            }
        } catch let quarantineError {
            var rollbackFailed = false
            for item in moved.reversed() {
                do {
                    try moveItem(item.quarantined, item.original)
                } catch {
                    rollbackFailed = true
                }
            }
            if !rollbackFailed {
                try? fileManager.removeItem(at: recoveryDirectory)
            }
            throw quarantineError
        }
    }
}
