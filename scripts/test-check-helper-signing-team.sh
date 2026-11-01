#!/usr/bin/env bash
set -uo pipefail

# test-check-helper-signing-team.sh
#
# Automated coverage for scripts/check-helper-signing-team.sh (the release.yml check that the
# helper's SpawnConstraint team and the nested helper's signature match the app's signing team).
# A real Developer ID signature isn't available off the release runner, so each scenario builds a
# stand-in Salvage.app layout in a temp dir and a fake `codesign` (via CODESIGN) that reports the
# Team IDs the scenario chooses. Exits 0 only when every scenario behaves as expected.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$root/scripts/check-helper-signing-team.sh"
status=0

work="$(mktemp -d "${TMPDIR:-/tmp}/salvage-test-helper-team.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT

fake_codesign="$work/codesign"
cat > "$fake_codesign" <<'FAKE'
#!/bin/sh
# Mimics `codesign -dv --verbose=4 PATH`: details on stderr. FAKE_APP_TEAM / FAKE_HELPER_TEAM
# choose the reported team ("unsigned" fails like an unsigned binary, "" omits the line).
for target; do :; done
case "$target" in
    */Contents/MacOS/SalvageHelper) team="$FAKE_HELPER_TEAM"; identifier=dev.hsmith.Salvage.Helper ;;
    *) team="$FAKE_APP_TEAM"; identifier=dev.hsmith.Salvage ;;
esac
if [ "$team" = "unsigned" ]; then
    echo "$target: code object is not signed at all" >&2
    exit 1
fi
echo "Executable=$target" >&2
echo "Identifier=$identifier" >&2
[ -n "$team" ] && echo "TeamIdentifier=$team" >&2
exit 0
FAKE
chmod +x "$fake_codesign"

TEAM="ABCDE12345"
OTHER="ZYXWV98765"

# make_app SPAWN_TEAM [SPAWN_IDENTIFIER] -> prints the app path. SPAWN_TEAM "-" omits the key.
make_app() {
    local spawn_team="$1" spawn_identifier="${2:-dev.hsmith.Salvage.Helper}"
    local app="$work/app-$RANDOM$RANDOM/Salvage.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchDaemons"
    : > "$app/Contents/MacOS/Salvage"
    : > "$app/Contents/MacOS/SalvageHelper"
    local plist="$app/Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist"
    cp "$root/SalvageHelper/dev.hsmith.Salvage.Helper.plist" "$plist"
    /usr/libexec/PlistBuddy -c "Set :SpawnConstraint:signing-identifier $spawn_identifier" "$plist"
    if [ "$spawn_team" != "-" ]; then
        /usr/libexec/PlistBuddy -c "Add :SpawnConstraint:team-identifier string $spawn_team" "$plist"
    fi
    printf '%s\n' "$app"
}

# expect LABEL pass|fail EXPECTED_OUTPUT APP_TEAM HELPER_TEAM APP [EXPECTED_TEAM]
expect() {
    local label="$1" outcome="$2" grep_for="$3" app_team="$4" helper_team="$5" app="$6" expected="${7:-}"
    local output exit_code
    output="$(CODESIGN="$fake_codesign" FAKE_APP_TEAM="$app_team" FAKE_HELPER_TEAM="$helper_team" \
        "$checker" "$app" ${expected:+"$expected"} 2>&1)"
    exit_code=$?
    if [ "$outcome" = "pass" ] && [ "$exit_code" -ne 0 ]; then
        echo "FAIL [$label]: expected exit 0, got $exit_code"; echo "$output"; status=1; return
    fi
    if [ "$outcome" = "fail" ] && [ "$exit_code" -eq 0 ]; then
        echo "FAIL [$label]: expected non-zero exit, got 0"; echo "$output"; status=1; return
    fi
    if ! printf '%s\n' "$output" | grep -qF -- "$grep_for"; then
        echo "FAIL [$label]: expected output to contain: $grep_for"; echo "$output"; status=1; return
    fi
    echo "PASS [$label]"
}

expect "everything signed by one team, plist pins it" pass "all use team $TEAM" "$TEAM" "$TEAM" "$(make_app "$TEAM")"
expect "matches the requested DEVELOPMENT_TEAM" pass "all use team $TEAM" "$TEAM" "$TEAM" "$(make_app "$TEAM")" "$TEAM"
expect "app signed by a different team than requested" fail "asked for DEVELOPMENT_TEAM '$OTHER'" \
    "$TEAM" "$TEAM" "$(make_app "$TEAM")" "$OTHER"
expect "SpawnConstraint pins another team" fail "SpawnConstraint team-identifier '$OTHER' does not match" \
    "$TEAM" "$TEAM" "$(make_app "$OTHER")"
expect "SpawnConstraint has no team-identifier" fail "no SpawnConstraint team-identifier" \
    "$TEAM" "$TEAM" "$(make_app -)"
expect "SpawnConstraint pins another signing identifier" fail "signing-identifier 'dev.example.Other' is not" \
    "$TEAM" "$TEAM" "$(make_app "$TEAM" dev.example.Other)"
expect "helper signed by another team" fail "SalvageHelper is signed by team '$OTHER'" \
    "$TEAM" "$OTHER" "$(make_app "$TEAM")"
expect "helper not signed" fail "could not read the signature" "$TEAM" unsigned "$(make_app "$TEAM")"
expect "app has no Team ID (ad-hoc)" fail "has no valid signing Team ID" "" "$TEAM" "$(make_app "$TEAM")"
expect "app Team ID 'not set'" fail "has no valid signing Team ID" "not set" "not set" "$(make_app "not set")"

app="$(make_app "$TEAM")"; rm -f "$app/Contents/MacOS/SalvageHelper"
expect "nested helper missing" fail "nested helper not found" "$TEAM" "$TEAM" "$app"
app="$(make_app "$TEAM")"; rm -f "$app/Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist"
expect "helper plist missing" fail "helper launchd plist not found" "$TEAM" "$TEAM" "$app"
expect "app bundle missing" fail "app bundle not found" "$TEAM" "$TEAM" "$work/nowhere/Salvage.app"

echo
if [ "$status" -ne 0 ]; then
    echo "test-check-helper-signing-team.sh: FAILED"
else
    echo "test-check-helper-signing-team.sh: PASSED"
fi
exit "$status"
