#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

Scripts/bootstrap.sh
Scripts/verify-licenses.sh

destination="${TVOS_TEST_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation)}"
xcodebuild test \
  -project VPlayer.xcodeproj \
  -scheme VPlayer \
  -destination "$destination" \
  CODE_SIGNING_ALLOWED=NO
