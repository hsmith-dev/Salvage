#!/usr/bin/env bash
set -euo pipefail

# release-local.sh
#
# Builds, signs, notarizes and packages a Salvage release on the owner's own Mac (the local
# counterpart of .github/workflows/release.yml, AD-10). See docs/RELEASING.md, "Releasing from your
# own Mac", for the one-time setup.
#
#   release-local.sh [--dry-run] [--team TEAM_ID] [--profile NAME] [--out DIR] [--allow-dirty]
#
#   --team TEAM_ID   the 10-character Apple Developer Team ID. Default: $SALVAGE_TEAM_ID, else
#                    $DEVELOPMENT_TEAM. It is passed to xcodebuild for this run only and is never
#                    written to any file in the repository.
#   --profile NAME   the notarytool keychain profile made by `xcrun notarytool store-credentials`.
#                    Default: $SALVAGE_NOTARY_PROFILE, else "salvage-notary".
#   --out DIR        where Salvage-<version>.dmg and SHA256SUMS go. Default: build/release/<version>
#                    (git-ignored). Must not already hold that DMG.
#   --allow-dirty    allow uncommitted changes (otherwise a dirty work tree is refused).
#   --dry-run        run every preflight check (team, Developer ID certificate, notary profile, tools,
#                    version, output folder) and print each command a release would run, then stop.
#                    Builds nothing, signs nothing, uploads nothing. The profile check does ask
#                    Apple's notary service for your submission history (read-only).
#
# Steps of a real run, each one failing the run:
#   1. Preflight (as above). Every missing prerequisite is named, then the script stops.
#   2. Clean Release build of the Salvage scheme with DEVELOPMENT_TEAM=<team>, manual signing as
#      "Developer ID Application", hardened runtime and a secure timestamp. Xcode signs the nested
#      SalvageHelper first, then the app, and pins the helper's SpawnConstraint to the team.
#   3. Verify: `codesign --verify --deep --strict` on the app; hardened runtime and a timestamp on
#      the app and the helper; the helper's identifier; scripts/check-helper-signing-team.sh.
#   4. Notarize the app (`xcrun notarytool submit --keychain-profile <profile> --wait`), staple it,
#      validate the ticket and run `spctl -a -vv` on it.
#   5. Package with scripts/package-release.sh --release --notary-profile <profile>, which signs,
#      notarizes and staples the DMG and writes SHA256SUMS.
#   6. Verify the DMG: checksum, stapled ticket, `spctl -a -vv -t open`.
#
# The version is MARKETING_VERSION from project.yml (one value for the app, the helper and, by a
# test, the CLI). Exit codes: 0 success (or a clean dry run); 1 a check or a tool failed; 2 usage.
# Tools can be overridden for scripts/test-release-local.sh: XCODEBUILD, XCRUN, CODESIGN, SECURITY,
# SPCTL, GIT (and HDIUTIL, passed through to package-release.sh).

XCODEBUILD="${XCODEBUILD:-xcodebuild}"
XCRUN="${XCRUN:-xcrun}"
CODESIGN="${CODESIGN:-codesign}"
SECURITY="${SECURITY:-security}"
SPCTL="${SPCTL:-spctl}"
GIT="${GIT:-git}"
export CODESIGN XCRUN  # check-helper-signing-team.sh and package-release.sh honour these

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper_identifier="dev.hsmith.Salvage.Helper"

usage() {
    sed -n '10,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}
log() { echo "release-local: $*"; }
fail() { echo "release-local: error: $*" >&2; exit 1; }

dry_run=0
allow_dirty=0
team="${SALVAGE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
profile="${SALVAGE_NOTARY_PROFILE:-salvage-notary}"
outdir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --allow-dirty) allow_dirty=1 ;;
        --team) [ $# -ge 2 ] || usage; team="$2"; shift ;;
        --profile) [ $# -ge 2 ] || usage; profile="$2"; shift ;;
        --out) [ $# -ge 2 ] || usage; outdir="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "release-local: unknown argument $1" >&2; usage ;;
    esac
    shift
done

# --- 1. Preflight: collect every problem, then stop if there is any. ---
problems=()
problem() { problems+=("$1"); echo "release-local: MISSING: $1" >&2; }
ok() { log "ok: $*"; }

version="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$root/project.yml" | sort -u)"
if [ "$(printf '%s\n' "$version" | grep -c .)" -ne 1 ]; then
    problem "project.yml must set one MARKETING_VERSION for every target (found: $(printf '%s' "$version" | tr '\n' ' '))"
elif ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    problem "MARKETING_VERSION '$version' in project.yml is not of the form X.Y.Z"
else
    ok "version $version (project.yml)"
fi

if [ -z "$team" ]; then
    problem "no Team ID: pass --team TEAM_ID or set SALVAGE_TEAM_ID (Xcode > Settings > Accounts > your team, or developer.apple.com > Account > Membership details)"
elif ! printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$'; then
    problem "Team ID '$team' is not 10 capital letters and digits"
    team=""
else
    ok "team $team (from the command line or environment; not stored)"
fi

for tool in "$XCODEBUILD" "$XCRUN" "$CODESIGN" "$SECURITY" "$SPCTL"; do
    command -v "$tool" >/dev/null 2>&1 || problem "required tool not found: $tool (install Xcode and run xcode-select)"
done

identity=""
if [ -n "$team" ]; then
    identities="$("$SECURITY" find-identity -v -p codesigning 2>/dev/null || true)"
    identity="$(printf '%s\n' "$identities" | sed -n "s/.*\"\(Developer ID Application: .* ($team)\)\".*/\1/p" | head -n 1)"
    if [ -n "$identity" ]; then
        ok "signing identity \"$identity\""
    else
        problem "no valid \"Developer ID Application: ... ($team)\" certificate with its private key in your keychain (check: security find-identity -v -p codesigning; create one in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application)"
    fi
fi

if [ -z "$profile" ]; then
    problem "no notary profile name: pass --profile NAME or set SALVAGE_NOTARY_PROFILE"
elif "$XCRUN" notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    ok "notary keychain profile '$profile' works"
else
    problem "notary keychain profile '$profile' is missing or its credentials are rejected (create it once: xcrun notarytool store-credentials $profile --apple-id <you@example.com> --team-id <TEAM_ID>)"
fi

if [ "$allow_dirty" -eq 0 ]; then
    if ! dirty="$("$GIT" -C "$root" status --porcelain 2>/dev/null)"; then
        problem "could not read git status of $root (pass --allow-dirty to skip this check)"
    elif [ -n "$dirty" ]; then
        problem "the work tree has uncommitted changes; commit them or pass --allow-dirty"
    else
        ok "work tree is clean at $("$GIT" -C "$root" rev-parse --short HEAD 2>/dev/null || echo '?')"
    fi
fi

[ -n "$outdir" ] || outdir="$root/build/release/${version:-unknown}"
if [ -e "$outdir/Salvage-$version.dmg" ] || [ -e "$outdir/SHA256SUMS" ]; then
    problem "$outdir already holds a DMG or SHA256SUMS; move them away or pass --out"
fi

if [ "${#problems[@]}" -gt 0 ]; then
    echo "release-local: ${#problems[@]} prerequisite(s) missing; nothing was built, signed or uploaded." >&2
    exit 1
fi

# DerivedData, the build log and the notarization zip. RELEASE_WORK_DIR overrides it (self-test).
work_root="${RELEASE_WORK_DIR:-$root/build/release-work}"
derived_data="$work_root/DerivedData"
app="$derived_data/Build/Products/Release/Salvage.app"
zip_path="$work_root/Salvage-$version-notarize.zip"
build_log="$work_root/xcodebuild-$version.log"

build_cmd=("$XCODEBUILD" -project "$root/Salvage.xcodeproj" -scheme Salvage -configuration Release
    -destination 'platform=macOS' -derivedDataPath "$derived_data"
    DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application"
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" clean build)
package_cmd=("$root/scripts/package-release.sh" --release --identity "$identity" --notary-profile "$profile"
    "$app" "$version" "$outdir")

if [ "$dry_run" -eq 1 ]; then
    log "dry run: every prerequisite is in place. A release would run:"
    log "  $(printf '%q ' "${build_cmd[@]}")> $build_log"
    log "  $CODESIGN --verify --deep --strict --verbose=2 $app"
    log "  $root/scripts/check-helper-signing-team.sh $app $team"
    log "  ditto -c -k --keepParent $app $zip_path"
    log "  $XCRUN notarytool submit $zip_path --keychain-profile $profile --wait"
    log "  $XCRUN stapler staple $app && $XCRUN stapler validate $app"
    log "  $SPCTL -a -vv -t execute $app"
    log "  DEVELOPMENT_TEAM=$team $(printf '%q ' "${package_cmd[@]}")"
    log "  $SPCTL -a -vv -t open --context context:primary-signature $outdir/Salvage-$version.dmg"
    log "dry run: nothing was built, signed or uploaded."
    exit 0
fi

# notarize FILE: submit with the keychain profile and wait; fail unless Apple accepted it.
notarize() {
    local file="$1" output id
    log "notarizing $(basename "$file") (this usually takes a few minutes)..."
    output="$("$XCRUN" notarytool submit "$file" --keychain-profile "$profile" --wait 2>&1)" || {
        printf '%s\n' "$output" >&2; fail "notarytool submit failed for $file"; }
    printf '%s\n' "$output"
    if ! printf '%s\n' "$output" | grep -Eq '^[[:space:]]*status: Accepted[[:space:]]*$'; then
        id="$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*id: //p' | head -n 1)"
        fail "Apple did not accept $(basename "$file"); see why with: $XCRUN notarytool log ${id:-<submission id>} --keychain-profile $profile"
    fi
}

# --- 2. Build ---
mkdir -p "$work_root"
log "building Release (log: $build_log)..."
if ! "${build_cmd[@]}" > "$build_log" 2>&1; then
    tail -40 "$build_log" >&2
    fail "xcodebuild failed; full log: $build_log"
fi
[ -d "$app" ] || fail "the build succeeded but $app is missing"

# --- 3. Verify signatures ---
"$CODESIGN" --verify --deep --strict --verbose=2 "$app" || fail "the app's signature does not verify"
helper="$app/Contents/MacOS/SalvageHelper"
"$CODESIGN" --verify --strict --verbose=2 "$helper" || fail "SalvageHelper's signature does not verify"
for target in "$app" "$helper"; do
    info="$("$CODESIGN" --display --verbose=4 "$target" 2>&1)" || fail "codesign cannot read $target"
    printf '%s\n' "$info" | grep -Eq '^Authority=Developer ID Application: ' \
        || fail "$(basename "$target") is not signed with a Developer ID Application certificate"
    printf '%s\n' "$info" | grep -q 'flags=.*runtime' || fail "$(basename "$target") lacks the hardened runtime"
    printf '%s\n' "$info" | grep -q '^Timestamp=' || fail "$(basename "$target") lacks a secure timestamp"
    # Notarization rejects the debugging entitlement Xcode injects unless told not to.
    entitlements="$("$CODESIGN" --display --entitlements - --xml "$target" 2>/dev/null || true)"
    if printf '%s' "$entitlements" | grep -q 'com.apple.security.get-task-allow'; then
        fail "$(basename "$target") has the com.apple.security.get-task-allow entitlement, which notarization rejects"
    fi
done
helper_id="$("$CODESIGN" --display --verbose=4 "$helper" 2>&1 | sed -n 's/^Identifier=//p')"
[ "$helper_id" = "$helper_identifier" ] || fail "SalvageHelper is signed as '$helper_id', expected $helper_identifier"
"$root/scripts/check-helper-signing-team.sh" "$app" "$team" || fail "helper signing-team check failed"
log "signatures verified (Developer ID, hardened runtime, timestamp, team $team)"

# --- 4. Notarize and staple the app ---
rm -f "$zip_path"
ditto -c -k --keepParent "$app" "$zip_path"
notarize "$zip_path"
rm -f "$zip_path"
"$XCRUN" stapler staple "$app" || fail "stapling the app failed"
"$XCRUN" stapler validate "$app" || fail "the app's stapled ticket does not validate"
"$SPCTL" -a -vv -t execute "$app" || fail "Gatekeeper rejects the notarized app"

# --- 5. Package, sign, notarize and staple the DMG ---
DEVELOPMENT_TEAM="$team" "${package_cmd[@]}" || fail "packaging failed"
dmg="$outdir/Salvage-$version.dmg"

# --- 6. Verify the DMG ---
(cd "$outdir" && shasum -a 256 -c --strict SHA256SUMS) || fail "SHA256SUMS does not match the DMG"
"$XCRUN" stapler validate "$dmg" || fail "the DMG's stapled ticket does not validate"
"$SPCTL" -a -vv -t open --context context:primary-signature "$dmg" || fail "Gatekeeper rejects the DMG"

log "done: $dmg"
log "      $outdir/SHA256SUMS"
log "next: docs/RELEASE-CHECKLIST.md, then attach both files to the GitHub release for v$version."
