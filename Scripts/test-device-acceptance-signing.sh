#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/vplayer-acceptance-signing.XXXXXX")"

cleanup() {
    rm -f \
        "$test_directory/wrong-key.pem" \
        "$test_directory/wrong-cert.pem" \
        "$test_directory/right-key.pem" \
        "$test_directory/right-cert.pem"
    rmdir "$test_directory" 2>/dev/null || true
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$test_directory/wrong-key.pem" \
    -out "$test_directory/wrong-cert.pem" \
    -days 1 \
    -subj '/CN=Apple Development: Duplicate Name/OU=TEAMWRONG1' \
    >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$test_directory/right-key.pem" \
    -out "$test_directory/right-cert.pem" \
    -days 1 \
    -subj '/CN=Apple Development: Duplicate Name/OU=TEAMRIGHT1' \
    >/dev/null 2>&1

wrong_fingerprint="$(
    openssl x509 -in "$test_directory/wrong-cert.pem" -noout -fingerprint -sha1 \
        | sed -E 's/^.*=//; s/://g'
)"
right_fingerprint="$(
    openssl x509 -in "$test_directory/right-cert.pem" -noout -fingerprint -sha1 \
        | sed -E 's/^.*=//; s/://g'
)"

signing_identities="$(printf '%s\n' \
    '  1) 1111111111111111111111111111111111111111 "Developer ID Application: Wrong First"' \
    '  2) 2222222222222222222222222222222222222222 "Apple Distribution: Wrong First"' \
    "  3) $right_fingerprint \"Apple Development: Duplicate Name\"" \
    "  4) $wrong_fingerprint \"Apple Development: Duplicate Name\"" \
    '     4 valid identities found')"
signing_certificates="$(
    printf 'SHA-1 hash: %s\n' "$wrong_fingerprint"
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
        "$test_directory/wrong-cert.pem"
    printf 'SHA-1 hash: %s\n' "$right_fingerprint"
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
        "$test_directory/right-cert.pem"
)"

# shellcheck source=resolve-acceptance-development-team.sh
if [[ ! -r "$script_dir/resolve-acceptance-development-team.sh" ]]; then
    echo "signing resolver is missing" >&2
    exit 1
fi
source "$script_dir/resolve-acceptance-development-team.sh"

actual_team="$(
    resolve_acceptance_development_team "$signing_identities" "$signing_certificates"
)"
[[ "$actual_team" == "TEAMRIGHT1" ]]
