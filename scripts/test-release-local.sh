#!/usr/bin/env bash
set -uo pipefail

# test-release-local.sh
#
# Self-test for scripts/release-local.sh. Needs no certificate, Team ID, notary profile or network:
# every Apple tool (xcodebuild, xcrun notarytool/stapler, codesign, security, spctl, hdiutil, git)
# is replaced by a fake in a temp dir that records its calls. Covers:
#   1. Usage errors (exit 2).
#   2. Fail-closed preflight: no team, a malformed team, no Developer ID certificate for the team,
#      a missing notary profile, a dirty work tree, an output folder that already holds a DMG.
#      None of them may run xcodebuild or create an output.
#   3. --dry-run with everything in place: exit 0, the plan names the keychain profile, nothing is
#      built or uploaded.
#   4. A full run against the fakes: build -> verify -> notarize app -> staple -> spctl ->
#      package-release.sh --release --notary-profile -> DMG notarized and stapled -> SHA256SUMS.
#   5. Failures after preflight: the build fails, Apple returns "Invalid", the helper lacks the
#      hardened runtime. Each must stop the run without a DMG.
# Exits 0 only when every scenario passes.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/release-local.sh"
status=0

work="$(mktemp -d "${TMPDIR:-/tmp}/salvage-test-release-local.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"
calls="$work/calls.log"

TEAM="ABCDE12345"   # a stand-in, not a real Team ID
version="$(sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "$root/project.yml" | sort -u)"

# --- Fakes. Each appends "<tool> <args>" to $CALLS. ---
cat > "$bin/security" <<'FAKE'
#!/bin/sh
echo "security $*" >> "$CALLS"
if [ "$1" = "find-identity" ] && [ -n "${FAKE_IDENTITY_TEAM:-}" ]; then
    echo "  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"Developer ID Application: Test Org ($FAKE_IDENTITY_TEAM)\""
    echo "     1 valid identities found"
fi
exit 0
FAKE

cat > "$bin/xcrun" <<'FAKE'
#!/bin/sh
echo "xcrun $*" >> "$CALLS"
case "$1 $2" in
    "notarytool history") [ "${FAKE_PROFILE_OK:-1}" = 1 ] ;;
    "notarytool submit")
        echo "Conducting pre-submission checks for $3 and initiating connection to the Apple notary service..."
        echo "  id: 11111111-2222-3333-4444-555555555555"
        echo "  status: ${FAKE_NOTARY_STATUS:-Accepted}"
        exit 0 ;;
    "stapler staple"|"stapler validate") exit 0 ;;
    *) echo "fake xcrun: unexpected $*" >&2; exit 1 ;;
esac
FAKE

cat > "$bin/xcodebuild" <<'FAKE'
#!/bin/sh
echo "xcodebuild $*" >> "$CALLS"
[ "${FAKE_BUILD_FAIL:-0}" = 1 ] && { echo "** BUILD FAILED **"; exit 65; }
dd=""; team=""
while [ $# -gt 0 ]; do
    case "$1" in
        -derivedDataPath) dd="$2"; shift ;;
        DEVELOPMENT_TEAM=*) team="${1#DEVELOPMENT_TEAM=}" ;;
    esac
    shift
done
app="$dd/Build/Products/Release/Salvage.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchDaemons"
printf '#!/bin/sh\n' > "$app/Contents/MacOS/Salvage"
printf '#!/bin/sh\n' > "$app/Contents/MacOS/SalvageHelper"
chmod +x "$app/Contents/MacOS/Salvage" "$app/Contents/MacOS/SalvageHelper"
plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string Salvage "$app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$FAKE_VERSION" "$app/Contents/Info.plist"
plist="$app/Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist"
cp "$REPO_ROOT/SalvageHelper/dev.hsmith.Salvage.Helper.plist" "$plist"
/usr/libexec/PlistBuddy -c "Add :SpawnConstraint:team-identifier string $team" "$plist"
echo "** BUILD SUCCEEDED **"
FAKE

cat > "$bin/codesign" <<'FAKE'
#!/bin/sh
echo "codesign $*" >> "$CALLS"
for target; do :; done
case " $* " in
    *" --sign "*) exit 0 ;;
    *" --verify "*) exit 0 ;;
esac
case "$target" in
    */Contents/MacOS/SalvageHelper) identifier=dev.hsmith.Salvage.Helper; flags="${FAKE_HELPER_FLAGS:-0x10000(runtime)}" ;;
    *.dmg) identifier=Salvage; flags="0x0(none)" ;;
    *) identifier=dev.hsmith.Salvage; flags="0x10000(runtime)" ;;
esac
{
    echo "Executable=$target"
    echo "Identifier=$identifier"
    echo "CodeDirectory v=20500 size=1 flags=$flags hashes=1+1 location=embedded"
    echo "Authority=Developer ID Application: Test Org ($FAKE_IDENTITY_TEAM)"
    echo "Timestamp=1 Nov 2026 at 12:00:00"
    echo "TeamIdentifier=$FAKE_IDENTITY_TEAM"
} >&2
exit 0
FAKE

cat > "$bin/spctl" <<'FAKE'
#!/bin/sh
echo "spctl $*" >> "$CALLS"
echo "accepted" >&2
echo "source=Notarized Developer ID" >&2
exit 0
FAKE

cat > "$bin/hdiutil" <<'FAKE'
#!/bin/sh
echo "hdiutil $*" >> "$CALLS"
for target; do :; done
case "$1" in
    create) printf 'fake disk image\n' > "$target" ;;
    verify) [ -f "$target" ] ;;
    *) exit 1 ;;
esac
FAKE

cat > "$bin/git" <<'FAKE'
#!/bin/sh
echo "git $*" >> "$CALLS"
case "$*" in
    *"status --porcelain"*) [ -n "${FAKE_DIRTY:-}" ] && echo " M project.yml"; exit 0 ;;
    *"rev-parse"*) echo abc1234 ;;
esac
exit 0
FAKE
chmod +x "$bin"/*

pass() { echo "PASS [$1]"; }
failed() { echo "FAIL [$1]: $2"; status=1; }

# run [ENV=VALUE...] -- ARGS... : runs release-local.sh with the fakes; sets $out_text, $exit_code.
run() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    : > "$calls"
    out_text="$(env -u SALVAGE_TEAM_ID -u DEVELOPMENT_TEAM -u SALVAGE_NOTARY_PROFILE \
        XCODEBUILD="$bin/xcodebuild" XCRUN="$bin/xcrun" CODESIGN="$bin/codesign" SECURITY="$bin/security" \
        SPCTL="$bin/spctl" HDIUTIL="$bin/hdiutil" GIT="$bin/git" CALLS="$calls" REPO_ROOT="$root" \
        FAKE_VERSION="$version" FAKE_IDENTITY_TEAM="$TEAM" RELEASE_WORK_DIR="$work/rw" \
        ${envs[@]+"${envs[@]}"} "$script" "$@" 2>&1)"
    exit_code=$?
}

# expect LABEL EXIT TEXT [ENV=VALUE...] -- ARGS...
expect() {
    local label="$1" want="$2" text="$3"; shift 3
    run "$@"
    if [ "$exit_code" -ne "$want" ]; then failed "$label" "expected exit $want, got $exit_code"; echo "$out_text"; return 1; fi
    if ! printf '%s\n' "$out_text" | grep -qF -- "$text"; then failed "$label" "output lacks: $text"; echo "$out_text"; return 1; fi
    pass "$label"
}
not_built() {
    if grep -q '^xcodebuild ' "$calls" || grep -q 'notarytool submit' "$calls"; then
        failed "$1" "built or submitted something:"; cat "$calls"
    else
        pass "$1: nothing built or submitted"
    fi
}

out="$work/out"
[ -n "$version" ] || { echo "FAIL: no MARKETING_VERSION in project.yml"; exit 1; }

# --- 1. Usage ---
expect "unknown argument" 2 "unknown argument" -- --bogus
expect "--help" 2 "--dry-run" -- --help

# --- 2. Fail-closed preflight ---
expect "no team" 1 "no Team ID" -- --out "$out" && not_built "no team"
expect "malformed team" 1 "is not 10 capital letters" -- --team abc --out "$out" && not_built "malformed team"
expect "no Developer ID certificate" 1 "Developer ID Application: ... ($TEAM)" FAKE_IDENTITY_TEAM=ZYXWV98765 -- \
    --team "$TEAM" --out "$out" && not_built "no certificate"
expect "notary profile missing" 1 "notary keychain profile 'nope' is missing" FAKE_PROFILE_OK=0 -- \
    --team "$TEAM" --profile nope --out "$out" && not_built "no profile"
expect "every problem is named at once" 1 "3 prerequisite(s) missing" FAKE_PROFILE_OK=0 FAKE_DIRTY=1 -- \
    --team abc --out "$out"
expect "dirty work tree" 1 "uncommitted changes" FAKE_DIRTY=1 -- --team "$TEAM" --out "$out" && not_built "dirty tree"
expect "dirty tree allowed with --allow-dirty" 0 "every prerequisite is in place" FAKE_DIRTY=1 -- \
    --dry-run --allow-dirty --team "$TEAM" --out "$out"
mkdir -p "$work/full"; : > "$work/full/Salvage-$version.dmg"
expect "output already holds a DMG" 1 "already holds a DMG" -- --team "$TEAM" --out "$work/full" && not_built "existing DMG"
[ ! -e "$out" ] && pass "no failed preflight created the output folder" || failed "output folder" "$out exists"

# --- 3. Dry run ---
expect "dry run with the team from SALVAGE_TEAM_ID" 0 "--keychain-profile test-profile --wait" \
    SALVAGE_TEAM_ID="$TEAM" SALVAGE_NOTARY_PROFILE=test-profile -- --dry-run --out "$out" && not_built "dry run"
printf '%s\n' "$out_text" | grep -qF "DEVELOPMENT_TEAM=$TEAM" && pass "dry run shows the build team" \
    || failed "dry run plan" "no DEVELOPMENT_TEAM in the plan"
[ ! -e "$out" ] && [ ! -e "$work/rw" ] && pass "dry run wrote nothing" || failed "dry run" "created files"

# --- 4. Full run against the fakes ---
if expect "full release run" 0 "done: $out/Salvage-$version.dmg" -- --team "$TEAM" --profile test-profile --out "$out"; then
    [ -f "$out/Salvage-$version.dmg" ] && (cd "$out" && shasum -a 256 -c --strict SHA256SUMS >/dev/null) \
        && pass "DMG and a matching SHA256SUMS were written" || failed "outputs" "$(ls -A "$out")"
    grep -q "^xcodebuild .*-configuration Release.*DEVELOPMENT_TEAM=$TEAM.*CODE_SIGN_IDENTITY=Developer ID Application.*ENABLE_HARDENED_RUNTIME=YES" "$calls" \
        && pass "Release build with the team, Developer ID and hardened runtime" || failed "build args" "$(grep '^xcodebuild' "$calls")"
    grep -q "^codesign --verify --deep --strict" "$calls" && pass "codesign --verify --deep --strict ran" \
        || failed "verify" "no deep strict verify"
    [ "$(grep -c "notarytool submit .*--keychain-profile test-profile --wait" "$calls")" -eq 2 ] \
        && pass "app and DMG notarized with the keychain profile" || failed "notarize" "$(grep notarytool "$calls")"
    [ "$(grep -c "^xcrun stapler staple" "$calls")" -eq 2 ] && pass "app and DMG stapled" || failed "staple" "count"
    grep -q "^spctl -a -vv -t execute .*Salvage.app" "$calls" && grep -q "^spctl -a -vv -t open .*\.dmg" "$calls" \
        && pass "spctl -a -vv on the app and the DMG" || failed "spctl" "$(grep spctl "$calls")"
    order="$(grep -nE '^(xcodebuild|xcrun notarytool submit|xcrun stapler staple|hdiutil create)' "$calls" | cut -d' ' -f1-3 | tr '\n' '|')"
    case "$order" in
        *xcodebuild*notarytool\ submit*stapler\ staple*hdiutil\ create*notarytool\ submit*stapler\ staple*) pass "steps ran in order" ;;
        *) failed "order" "$order" ;;
    esac
    if grep -rqF "$TEAM" "$root/project.yml" "$root/Salvage.xcodeproj" 2>/dev/null; then
        failed "team stored" "the Team ID was written into the project"
    else
        pass "the Team ID was not written into project.yml or the xcodeproj"
    fi
fi

# --- 5. Failures after preflight ---
expect "build failure stops the run" 1 "xcodebuild failed" FAKE_BUILD_FAIL=1 -- --team "$TEAM" --out "$work/o5"
[ ! -e "$work/o5/Salvage-$version.dmg" ] && pass "no DMG after a build failure" || failed "build failure" "DMG exists"
expect "notarization Invalid stops the run" 1 "Apple did not accept" FAKE_NOTARY_STATUS=Invalid -- --team "$TEAM" --out "$work/o6"
printf '%s\n' "$out_text" | grep -qF "notarytool log 11111111-2222-3333-4444-555555555555" \
    && pass "the rejection names the notarytool log command" || failed "rejection hint" "no log command"
[ ! -e "$work/o6/Salvage-$version.dmg" ] && pass "no DMG after a rejected notarization" || failed "rejected" "DMG exists"
expect "helper without hardened runtime stops the run" 1 "SalvageHelper lacks the hardened runtime" \
    FAKE_HELPER_FLAGS="0x0(none)" -- --team "$TEAM" --out "$work/o7"
grep -q "notarytool submit" "$calls" && failed "unsigned helper" "was submitted" || pass "nothing submitted with a bad helper"

if [ "$status" -eq 0 ]; then echo "All release-local scenarios passed."; else echo "Some scenarios FAILED."; fi
exit "$status"
