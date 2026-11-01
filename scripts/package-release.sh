#!/usr/bin/env bash
set -euo pipefail

# package-release.sh
#
# Packages a built Salvage.app into the release disk image (spec-tech-batch-6 §E, AD-10).
#
#   package-release.sh (--dry-run | --release) [--identity NAME] [--keychain PATH] \
#       [--notary-profile NAME] <Salvage.app> <version> <outdir>
#
# Steps, in order:
#   1. Verify the app bundle layout: the embedded helper at Contents/MacOS/SalvageHelper and its
#      launchd plist at Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist, with
#      BundleProgram pointing at the helper (the same checks ci.yml runs).
#   2. Build a compressed UDZO disk image holding Salvage.app and an /Applications symlink, with
#      the volume name "Salvage <version>".
#   3. --release only: sign the DMG with Developer ID, notarize it with `xcrun notarytool`,
#      staple the ticket and validate it.
#   4. Write <outdir>/Salvage-<version>.dmg and <outdir>/SHA256SUMS (computed last, because
#      stapling changes the file).
#
# Exactly one mode is required, so a release can never be produced by accident:
#   --dry-run   runs everything that needs no credentials (1, 2, 4) and prints the signing and
#               notarization commands it would have run. The DMG is unsigned.
#   --release   also runs 3. It needs, in the environment (the release.yml secret names):
#                 DEVELOPMENT_TEAM      -- the Team ID the app and the DMG must be signed by
#                 NOTARIZATION_API_KEY  -- "<KEY_ID>:<ISSUER_ID>:<base64 .p8 private key>"
#                                          (not needed with --notary-profile)
#               and a "Developer ID Application" identity in the keychain (--keychain selects
#               one; release.yml passes its temporary keychain). The app must already be signed
#               by DEVELOPMENT_TEAM and stapled, and its CFBundleShortVersionString must equal
#               <version>.
#   --notary-profile NAME   notarize with a `xcrun notarytool store-credentials` keychain profile
#               instead of NOTARIZATION_API_KEY (scripts/release-local.sh passes this).
#
# Exit codes: 0 success; 1 a check or a tool failed; 2 usage error.
# Tools can be overridden for tests: HDIUTIL, CODESIGN, XCRUN.

HDIUTIL="${HDIUTIL:-hdiutil}"
CODESIGN="${CODESIGN:-codesign}"
XCRUN="${XCRUN:-xcrun}"

helper_rel="Contents/MacOS/SalvageHelper"
plist_rel="Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist"

usage() {
    sed -n '8,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}
fail() { echo "package-release: error: $*" >&2; exit 1; }
log() { echo "package-release: $*"; }

mode=""
identity="Developer ID Application"
keychain=""
notary_profile=""
positional=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|--release)
            [ -z "$mode" ] || { echo "package-release: choose one of --dry-run or --release" >&2; exit 2; }
            mode="${1#--}" ;;
        --identity) [ $# -ge 2 ] || usage; identity="$2"; shift ;;
        --keychain) [ $# -ge 2 ] || usage; keychain="$2"; shift ;;
        --notary-profile) [ $# -ge 2 ] && [ -n "$2" ] || usage; notary_profile="$2"; shift ;;
        -h|--help) usage ;;
        --*) echo "package-release: unknown option $1" >&2; usage ;;
        *) positional+=("$1") ;;
    esac
    shift
done
[ -n "$mode" ] || { echo "package-release: one of --dry-run or --release is required" >&2; usage; }
[ "${#positional[@]}" -eq 3 ] || usage

app="${positional[0]%/}"
version="${positional[1]}"
outdir="${positional[2]}"

# A strict version keeps the file name and volume name predictable (and free of path separators).
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.]+)?$'; then
    fail "version '$version' is not of the form X.Y.Z (optionally -suffix); pass it without the leading 'v'"
fi

volume_name="Salvage $version"
dmg_name="Salvage-$version.dmg"

# --- Release mode: check credentials before any work, naming everything that is missing. ---
if [ "$mode" = "release" ]; then
    missing=()
    [ -n "${DEVELOPMENT_TEAM:-}" ] || missing+=("DEVELOPMENT_TEAM")
    if [ -z "$notary_profile" ]; then
        [ -n "${NOTARIZATION_API_KEY:-}" ] || missing+=("NOTARIZATION_API_KEY")
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        fail "--release needs these environment variables: ${missing[*]} (nothing was packaged)"
    fi
fi
if [ "$mode" = "release" ] && [ -z "$notary_profile" ]; then
    api_key_compact="$(printf '%s' "$NOTARIZATION_API_KEY" | tr -d '[:space:]')"
    IFS=':' read -r notary_key_id notary_issuer_id notary_key_b64 <<< "$api_key_compact"
    if [ -z "$notary_key_id" ] || [ -z "$notary_issuer_id" ] || [ -z "$notary_key_b64" ]; then
        fail "NOTARIZATION_API_KEY is malformed -- expected '<KEY_ID>:<ISSUER_ID>:<base64 .p8 key>'"
    fi
fi

# --- 1. App bundle layout ---
[ -d "$app" ] || fail "app bundle not found: $app"
[ "$(basename "$app")" = "Salvage.app" ] || fail "expected a bundle named Salvage.app, got $(basename "$app")"
[ -f "$app/Contents/Info.plist" ] || fail "missing Contents/Info.plist in $app"
executable="$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist" 2>/dev/null)" \
    || fail "Info.plist has no CFBundleExecutable"
[ -x "$app/Contents/MacOS/$executable" ] || fail "app executable not found: Contents/MacOS/$executable"
[ -x "$app/$helper_rel" ] || fail "nested helper not found or not executable: $helper_rel"
[ -f "$app/$plist_rel" ] || fail "helper launchd plist not found: $plist_rel"
plutil -lint -s "$app/$plist_rel" || fail "helper launchd plist does not parse: $plist_rel"
bundle_program="$(plutil -extract BundleProgram raw "$app/$plist_rel" 2>/dev/null || true)"
[ "$bundle_program" = "$helper_rel" ] \
    || fail "helper plist BundleProgram is '$bundle_program', expected '$helper_rel'"

app_version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null || true)"
if [ "$app_version" != "$version" ]; then
    if [ "$mode" = "release" ]; then
        fail "app reports version '$app_version' but the release is '$version'"
    fi
    log "warning: app reports version '$app_version', packaging as '$version' (allowed in --dry-run only)"
fi
log "bundle layout OK: $app (helper, launchd plist, BundleProgram)"

if [ "$mode" = "release" ]; then
    "$CODESIGN" --verify --deep --strict "$app" || fail "app signature does not verify"
    app_team="$("$CODESIGN" --display --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [ "$app_team" = "$DEVELOPMENT_TEAM" ] \
        || fail "app is signed by team '$app_team', expected DEVELOPMENT_TEAM '$DEVELOPMENT_TEAM'"
    "$XCRUN" stapler validate "$app" || fail "app has no stapled notarization ticket; notarize it first"
fi

# --- 2. Disk image ---
mkdir -p "$outdir"
outdir="$(cd "$outdir" && pwd)"
dmg="$outdir/$dmg_name"
sums="$outdir/SHA256SUMS"
[ ! -e "$dmg" ] || fail "$dmg already exists; refusing to overwrite it"
[ ! -e "$sums" ] || fail "$sums already exists; refusing to overwrite it"

work="$(mktemp -d "${TMPDIR:-/tmp}/salvage-package.XXXXXX")"
notary_key_path="$work/notary-key.p8"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

staging="$work/staging"
mkdir -p "$staging"
# ditto preserves the signature, extended attributes and the stapled ticket.
ditto "$app" "$staging/Salvage.app"
ln -s /Applications "$staging/Applications"

# Build into the work dir first, so a failure never leaves a partial DMG in outdir.
"$HDIUTIL" create -quiet \
    -volname "$volume_name" \
    -srcfolder "$staging" \
    -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 \
    "$work/$dmg_name" || fail "hdiutil create failed"
"$HDIUTIL" verify -quiet "$work/$dmg_name" || fail "hdiutil verify failed on the new image"
log "built $dmg_name (UDZO, volume \"$volume_name\")"

# --- 3. Sign, notarize, staple (release mode only) ---
sign_cmd=("$CODESIGN" --sign "$identity" --timestamp)
[ -z "$keychain" ] || sign_cmd+=(--keychain "$keychain")
sign_cmd+=("$work/$dmg_name")

if [ "$mode" = "release" ]; then
    "${sign_cmd[@]}" || fail "codesign of the DMG failed"
    "$CODESIGN" --verify --strict --verbose=2 "$work/$dmg_name" || fail "DMG signature does not verify"
    dmg_team="$("$CODESIGN" --display --verbose=4 "$work/$dmg_name" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [ "$dmg_team" = "$DEVELOPMENT_TEAM" ] \
        || fail "DMG is signed by team '$dmg_team', expected '$DEVELOPMENT_TEAM'"

    if [ -n "$notary_profile" ]; then
        "$XCRUN" notarytool submit "$work/$dmg_name" --keychain-profile "$notary_profile" \
            --wait || fail "notarization of the DMG failed"
    else
        printf '%s' "$notary_key_b64" | base64 --decode > "$notary_key_path" \
            || fail "NOTARIZATION_API_KEY's key part is not valid base64"
        "$XCRUN" notarytool submit "$work/$dmg_name" \
            --key "$notary_key_path" --key-id "$notary_key_id" --issuer "$notary_issuer_id" \
            --wait || fail "notarization of the DMG failed"
        rm -f "$notary_key_path"
    fi
    "$XCRUN" stapler staple "$work/$dmg_name" || fail "stapling the DMG failed"
    "$XCRUN" stapler validate "$work/$dmg_name" || fail "stapled ticket does not validate"
    log "signed, notarized and stapled $dmg_name"
else
    log "dry run: would sign:      $(printf '%q ' "${sign_cmd[@]}")"
    if [ -n "$notary_profile" ]; then
        log "dry run: would notarize:  $XCRUN notarytool submit $work/$dmg_name --keychain-profile $notary_profile --wait"
    else
        log "dry run: would notarize:  $XCRUN notarytool submit $work/$dmg_name --key <NOTARIZATION_API_KEY .p8> --key-id <KEY_ID> --issuer <ISSUER_ID> --wait"
    fi
    log "dry run: would staple:    $XCRUN stapler staple $work/$dmg_name && $XCRUN stapler validate $work/$dmg_name"
fi

# --- 4. Outputs ---
mv "$work/$dmg_name" "$dmg"
(cd "$outdir" && shasum -a 256 "$dmg_name" > SHA256SUMS)
log "wrote $dmg"
log "wrote $sums: $(cat "$sums")"
