#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v mint >/dev/null 2>&1 || {
  echo 'Mint is required. Run: brew bundle' >&2
  exit 1
}

mint bootstrap
mint run yonaskolb/XcodeGen@2.44.1 xcodegen generate --spec project.yml
test -f VPlayer.xcodeproj/project.pbxproj
