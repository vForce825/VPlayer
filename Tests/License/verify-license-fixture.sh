#!/usr/bin/env bash
set -euo pipefail

test -f LICENSE.APPSTORE-EXCEPTION
test -f NOTICE
test -f CONTRIBUTING.md
test -f THIRD_PARTY_NOTICES
test -x Scripts/verify-licenses.sh
grep -Fx '/docs/' .gitignore
test -z "$(git ls-files docs)"
Scripts/verify-licenses.sh
