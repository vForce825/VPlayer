#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

resolve_acceptance_development_team() {
    local signing_identities="$1"
    local signing_certificates="$2"
    local signing_fingerprint
    local selected_certificate
    local certificate_subject
    local development_team

    signing_fingerprint="$(
        sed -nE \
            's/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) "Apple Development:[^"]*"[[:space:]]*$/\1/p' \
            <<<"$signing_identities" \
            | sed -n '1p'
    )"
    [[ "$signing_fingerprint" =~ ^[A-Fa-f0-9]{40}$ ]] || return 1

    selected_certificate="$(
        awk -v wanted="$(tr '[:lower:]' '[:upper:]' <<<"$signing_fingerprint")" '
            /^SHA-1 hash: [A-Fa-f0-9]+[[:space:]]*$/ {
                fingerprint = toupper($3)
                selected = fingerprint == wanted
                in_pem = 0
                next
            }
            selected && /^-----BEGIN CERTIFICATE-----$/ {
                in_pem = 1
            }
            selected && in_pem {
                print
            }
            selected && /^-----END CERTIFICATE-----$/ {
                exit
            }
        ' <<<"$signing_certificates"
    )"
    [[ -n "$selected_certificate" ]] || return 1

    certificate_subject="$(
        openssl x509 -noout -subject -nameopt RFC2253 \
            <<<"$selected_certificate" 2>/dev/null
    )" || return 1
    development_team="$(
        sed -nE \
            's/^subject=[[:space:]]*([^,]*,)*OU=([A-Z0-9]{10})(,|$).*/\2/p' \
            <<<"$certificate_subject" \
            | sed -n '1p'
    )"
    [[ "$development_team" =~ ^[A-Z0-9]{10}$ ]] || return 1
    printf '%s\n' "$development_team"
}
