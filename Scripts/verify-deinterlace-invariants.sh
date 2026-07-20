#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY_ROOT}"

violations=0
if rg -n '(thermalState|waitUntilCompleted|fatalError)' Sources; then
    echo "deinterlace invariant failed: forbidden production source token" >&2
    violations=1
fi
if rg -n 'CVPixelBufferLockBaseAddress' Sources/VPlayerPlayback/Deinterlace; then
    echo "deinterlace invariant failed: CPU pixel-plane access in deinterlace sources" >&2
    violations=1
fi
if (( violations != 0 )); then
    exit 1
fi

xcodebuild test \
    -project VPlayer.xcodeproj \
    -scheme VPlayer \
    -destination 'platform=tvOS Simulator,id=66388132-B4CD-4089-81A6-F84D94BE3A73' \
    -parallel-testing-enabled NO \
    -only-testing:VPlayerTests/DeinterlacePipelineIntegrationTests
