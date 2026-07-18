#!/usr/bin/env bash
set -euo pipefail

expected_gpl_sha='3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986'
actual_gpl_sha="$(shasum -a 256 LICENSE | awk '{print $1}')"
[[ "$actual_gpl_sha" == "$expected_gpl_sha" ]] || {
  echo "LICENSE must remain the canonical GPLv3 text" >&2
  exit 1
}

rg -q '^VPlayer App Store Distribution Exception, version 1\.0$' LICENSE.APPSTORE-EXCEPTION
rg -q 'GPL-3\.0-only' NOTICE CONTRIBUTING.md
rg -q 'does not alter the license obligations of any third-party' LICENSE.APPSTORE-EXCEPTION

if [[ -d Sources ]]; then
  while IFS= read -r source_file; do
    rg -q 'SPDX-License-Identifier: GPL-3\.0-only' "$source_file" || {
      echo "Missing GPL SPDX identifier: $source_file" >&2
      exit 1
    }
    rg -q 'LICENSE\.APPSTORE-EXCEPTION' "$source_file" || {
      echo "Missing App Store exception comment: $source_file" >&2
      exit 1
    }
  done < <(find Sources -type f \( -name '*.swift' -o -name '*.metal' \) -print | sort)
fi
