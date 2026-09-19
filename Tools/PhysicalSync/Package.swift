// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import PackageDescription

let package = Package(
    name: "PhysicalSync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PhysicalSyncEvidence",
            targets: ["PhysicalSyncEvidence"]
        ),
        .executable(
            name: "physical-sync-evidence",
            targets: ["physical-sync-evidence"]
        )
    ],
    targets: [
        .target(
            name: "PhysicalSyncEvidence"
        ),
        .executableTarget(
            name: "physical-sync-evidence",
            dependencies: ["PhysicalSyncEvidence"]
        ),
        .testTarget(
            name: "PhysicalSyncEvidenceTests",
            dependencies: ["PhysicalSyncEvidence"]
        )
    ]
)
