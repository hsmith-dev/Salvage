#!/usr/bin/env bash
set -uo pipefail

# check-release-secrets.sh
#
# Verifies the release pipeline's four required secrets/variables are present, before any
# build/sign/notarize work happens (Architecture AD-10; spec-1-1's I/O & Edge-Case Matrix row
# "Tagged commit, signing secrets missing" -- the workflow must fail naming the missing secret,
# never publish a fake/unsigned artifact). Reads the four values from environment variables of
# the same name (set by .github/workflows/release.yml from `secrets.*`) rather than taking them
# as arguments, so a value is never echoed into a process listing or shell history.
#
# Required env vars:
#   DEVELOPER_ID_APPLICATION_CERT_P12 -- base64-encoded Developer ID Application .p12
#   DEVELOPER_ID_CERT_PASSWORD        -- password for that .p12
#   NOTARIZATION_API_KEY              -- "<KEY_ID>:<ISSUER_ID>:<base64 .p8 private key>"
#   DEVELOPMENT_TEAM                  -- HSmithDev LLC's Apple Developer Team ID
#
# Exits 0 if all four are non-empty. Exits 1 and names every missing one (never just the first)
# if any are empty/unset.

missing=()
[ -z "${DEVELOPER_ID_APPLICATION_CERT_P12:-}" ] && missing+=("DEVELOPER_ID_APPLICATION_CERT_P12")
[ -z "${DEVELOPER_ID_CERT_PASSWORD:-}" ] && missing+=("DEVELOPER_ID_CERT_PASSWORD")
[ -z "${NOTARIZATION_API_KEY:-}" ] && missing+=("NOTARIZATION_API_KEY")
[ -z "${DEVELOPMENT_TEAM:-}" ] && missing+=("DEVELOPMENT_TEAM")

if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error::Release workflow cannot sign/notarize this build -- missing required secret(s): ${missing[*]}"
    echo "No artifact was built or published. Configure the secret(s) named above in this repository's Settings > Secrets and variables > Actions, then re-push the tag."
    exit 1
fi

echo "All required signing/notarization secrets are present."
exit 0
