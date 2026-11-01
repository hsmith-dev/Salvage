#!/usr/bin/env bash
set -uo pipefail

# check-helper-signing-team.sh APP_PATH [EXPECTED_TEAM]
#
# Release check (Story 1.12 / AD-13), run by .github/workflows/release.yml after signing. Fails
# closed unless all of these hold for the signed Salvage.app:
#
#   1. The app's signing Team ID (`codesign -dv` -> TeamIdentifier) is a real 10-character team,
#      and equals EXPECTED_TEAM when one is given (the DEVELOPMENT_TEAM the build was asked for).
#   2. The nested privileged helper (Contents/MacOS/SalvageHelper) is signed with that same team.
#   3. The bundled launchd plist's SpawnConstraint pins that same team-identifier (and the
#      helper's signing-identifier), so launchd refuses to spawn a helper signed by anyone else.
#
# A missing file, an unreadable signature, an absent key or any mismatch is a failure, never a
# warning. CODESIGN overrides the codesign binary (for scripts/test-check-helper-signing-team.sh).

app="${1:-}"
expected_team="${2:-}"
codesign_tool="${CODESIGN:-codesign}"
helper_identifier="dev.hsmith.Salvage.Helper"

fail() {
    echo "::error::$1"
    echo "check-helper-signing-team.sh: FAILED"
    exit 1
}

[ -n "$app" ] || fail "usage: check-helper-signing-team.sh APP_PATH [EXPECTED_TEAM]"
[ -d "$app" ] || fail "app bundle not found: $app"
helper="$app/Contents/MacOS/SalvageHelper"
plist="$app/Contents/Library/LaunchDaemons/$helper_identifier.plist"
[ -f "$helper" ] || fail "nested helper not found: $helper"
[ -f "$plist" ] || fail "helper launchd plist not found: $plist"

# Sets team_result to the TeamIdentifier codesign reports for $1, or fails. (Not a command
# substitution, so a failure's message reaches the log and the exit ends this script.)
team_result=""
team_of() {
    local target="$1" info status team
    info="$("$codesign_tool" -dv --verbose=4 "$target" 2>&1)"
    status=$?
    [ "$status" -eq 0 ] || fail "codesign could not read the signature of $target (exit $status): $info"
    team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
    if ! printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$'; then
        fail "$target has no valid signing Team ID (TeamIdentifier='${team}')"
    fi
    team_result="$team"
}

team_of "$app"
app_team="$team_result"
echo "App signing Team ID: $app_team"
if [ -n "$expected_team" ] && [ "$app_team" != "$expected_team" ]; then
    fail "the app is signed by team '$app_team', but the build asked for DEVELOPMENT_TEAM '$expected_team'"
fi

team_of "$helper"
helper_team="$team_result"
echo "Helper signing Team ID: $helper_team"
[ "$helper_team" = "$app_team" ] \
    || fail "SalvageHelper is signed by team '$helper_team', but the app is signed by team '$app_team'"

plutil -lint "$plist" >/dev/null 2>&1 || fail "helper plist is not a valid property list: $plist"
spawn_team="$(/usr/libexec/PlistBuddy -c "Print :SpawnConstraint:team-identifier" "$plist" 2>/dev/null)" \
    || fail "helper plist has no SpawnConstraint team-identifier: $plist"
spawn_identifier="$(/usr/libexec/PlistBuddy -c "Print :SpawnConstraint:signing-identifier" "$plist" 2>/dev/null)" \
    || fail "helper plist has no SpawnConstraint signing-identifier: $plist"
echo "Helper SpawnConstraint: team-identifier=$spawn_team signing-identifier=$spawn_identifier"
[ "$spawn_team" = "$app_team" ] \
    || fail "helper SpawnConstraint team-identifier '$spawn_team' does not match the app's signing Team ID '$app_team'"
[ "$spawn_identifier" = "$helper_identifier" ] \
    || fail "helper SpawnConstraint signing-identifier '$spawn_identifier' is not $helper_identifier"

echo "OK: app, nested helper and helper SpawnConstraint all use team $app_team"
echo "check-helper-signing-team.sh: PASSED"
exit 0
