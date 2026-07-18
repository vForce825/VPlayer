// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import SwiftData

public enum VPlayerModelContainer {
    public static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            LibraryStateRecord.self,
            SourceProfileRecord.self,
            PlaylistSnapshotRecord.self,
            ChannelRecord.self,
            EPGSnapshotRecord.self,
            EPGChannelRecord.self,
            ProgrammeRecord.self,
            ManualEPGMappingRecord.self
        ])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try FileManager.default.createDirectory(
                at: applicationSupport,
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                schema: schema,
                url: applicationSupport.appendingPathComponent("VPlayer.store")
            )
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
