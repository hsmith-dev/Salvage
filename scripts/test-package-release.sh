#!/usr/bin/env bash
set -uo pipefail

# test-package-release.sh
#
# Self-test for scripts/package-release.sh (spec-tech-batch-6 §E). Never signs or notarizes:
#   1. Usage and fail-closed checks against stand-in bundles (bad version, no mode, missing helper,
#      missing plist, wrong BundleProgram, --release without credentials, refusing to overwrite).
#   2. Packages an unsigned Debug Salvage.app with --dry-run, mounts the DMG read-only in a temp
#      dir, checks the volume name, the contents (Salvage.app identical to the source, an
#      /Applications symlink, nothing else) and SHA256SUMS, then detaches. A corrupted copy must
#      fail the checksum.
#
#   test-package-release.sh [path/to/Salvage.app]
#
# The app comes from the argument, else $SALVAGE_APP, else an unsigned Debug build made here into a
# temp DerivedData folder (slow). Every image and mount point lives under one temp dir, and the
# image is detached and the dir deleted on exit. Exits 0 only when every scenario passes.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packager="$root/scripts/package-release.sh"
status=0

work="$(mktemp -d "${TMPDIR:-/tmp}/salvage-test-package.XXXXXX")" || exit 1
mountpoint="$work/mnt"
cleanup() {
    if mount | grep -qF " on $mountpoint "; then
        hdiutil detach -quiet "$mountpoint" || hdiutil detach -quiet -force "$mountpoint"
    fi
    rm -rf "$work"
}
trap cleanup EXIT

pass() { echo "PASS [$1]"; }
failed() { echo "FAIL [$1]: $2"; status=1; }

# expect LABEL EXPECTED_EXIT EXPECTED_OUTPUT -- packager args...
expect() {
    local label="$1" want_exit="$2" grep_for="$3"; shift 4
    local output exit_code
    output="$("$packager" "$@" 2>&1)"; exit_code=$?
    if [ "$exit_code" -ne "$want_exit" ]; then
        failed "$label" "expected exit $want_exit, got $exit_code"; echo "$output"; return
    fi
    if ! printf '%s\n' "$output" | grep -qF -- "$grep_for"; then
        failed "$label" "expected output to contain: $grep_for"; echo "$output"; return
    fi
    pass "$label"
}

# make_app -> prints a stand-in Salvage.app path with the layout ci.yml checks.
make_app() {
    local app="$work/fake-$RANDOM$RANDOM/Salvage.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchDaemons"
    printf '#!/bin/sh\n' > "$app/Contents/MacOS/Salvage"
    printf '#!/bin/sh\n' > "$app/Contents/MacOS/SalvageHelper"
    chmod +x "$app/Contents/MacOS/Salvage" "$app/Contents/MacOS/SalvageHelper"
    plutil -create xml1 "$app/Contents/Info.plist"
    plutil -insert CFBundleExecutable -string Salvage "$app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 9.9.9 "$app/Contents/Info.plist"
    cp "$root/SalvageHelper/dev.hsmith.Salvage.Helper.plist" "$app/Contents/Library/LaunchDaemons/"
    printf '%s\n' "$app"
}

# --- 1. Fail-closed checks (no image is created by any of these) ---
fake="$(make_app)"
expect "no mode flag" 2 "one of --dry-run or --release is required" -- "$fake" 1.0.0 "$work/o1"
expect "both mode flags" 2 "choose one of" -- --dry-run --release "$fake" 1.0.0 "$work/o1"
expect "version with leading v" 1 "is not of the form X.Y.Z" -- --dry-run "$fake" v1.0.0 "$work/o1"
expect "version with a slash" 1 "is not of the form X.Y.Z" -- --dry-run "$fake" 1.0.0/x "$work/o1"
expect "app missing" 1 "app bundle not found" -- --dry-run "$work/nowhere/Salvage.app" 1.0.0 "$work/o1"

app="$(make_app)"; rm "$app/Contents/MacOS/SalvageHelper"
expect "helper missing" 1 "nested helper not found" -- --dry-run "$app" 1.0.0 "$work/o1"
app="$(make_app)"; rm "$app/Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist"
expect "helper plist missing" 1 "helper launchd plist not found" -- --dry-run "$app" 1.0.0 "$work/o1"
app="$(make_app)"; plutil -replace BundleProgram -string Contents/MacOS/Other \
    "$app/Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist"
expect "wrong BundleProgram" 1 "BundleProgram is 'Contents/MacOS/Other'" -- --dry-run "$app" 1.0.0 "$work/o1"

output="$(env -u DEVELOPMENT_TEAM -u NOTARIZATION_API_KEY "$packager" --release "$fake" 9.9.9 "$work/o2" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$output" | grep -qF "DEVELOPMENT_TEAM NOTARIZATION_API_KEY" && [ ! -e "$work/o2" ]; then
    pass "--release without credentials names both and packages nothing"
else
    failed "--release without credentials" "$output"
fi
output="$(DEVELOPMENT_TEAM=ABCDE12345 NOTARIZATION_API_KEY=only-one-part "$packager" --release "$fake" 9.9.9 "$work/o2" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$output" | grep -qF "NOTARIZATION_API_KEY is malformed" && [ ! -e "$work/o2" ]; then
    pass "--release with a malformed API key packages nothing"
else
    failed "--release with a malformed API key" "$output"
fi
[ ! -e "$work/o1" ] && pass "no failed run created an output folder" || failed "outputs" "$work/o1 exists"

# --- 2. Dry-run package of a real unsigned Debug build ---
real_app="${1:-${SALVAGE_APP:-}}"
if [ -z "$real_app" ]; then
    echo "Building an unsigned Debug Salvage.app (pass a path or set SALVAGE_APP to skip this)..."
    if ! xcodebuild -project "$root/Salvage.xcodeproj" -scheme Salvage -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$work/DerivedData" \
        CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        build > "$work/build.log" 2>&1; then
        tail -30 "$work/build.log"; echo "FAIL [debug build]"; exit 1
    fi
    real_app="$work/DerivedData/Build/Products/Debug/Salvage.app"
fi

version="0.0.0-selftest"
out="$work/out"
if "$packager" --dry-run "$real_app" "$version" "$out"; then
    pass "dry-run packaging succeeded"
else
    failed "dry-run packaging" "exit $?"; exit 1
fi
dmg="$out/Salvage-$version.dmg"

[ "$(ls -A "$out" | LC_ALL=C sort | tr '\n' ' ')" = "SHA256SUMS Salvage-$version.dmg " ] \
    && pass "outdir holds exactly the DMG and SHA256SUMS" || failed "outdir contents" "$(ls -A "$out")"

(cd "$out" && shasum -a 256 -c --strict SHA256SUMS) && pass "SHA256SUMS verifies" || failed "checksum" "mismatch"

format="$(hdiutil imageinfo "$dmg" 2>/dev/null | sed -n 's/^Format: //p')"
[ "$format" = "UDZO" ] && pass "image format is UDZO" || failed "image format" "got '$format'"

expect "refuses to overwrite an existing DMG" 1 "refusing to overwrite" -- --dry-run "$real_app" "$version" "$out"

mkdir -p "$mountpoint"
if hdiutil attach -readonly -nobrowse -noautoopen -quiet -mountpoint "$mountpoint" "$dmg"; then
    pass "mounted read-only at a temp mount point"
    volname="$(diskutil info -plist "$mountpoint" | plutil -extract VolumeName raw - 2>/dev/null)"
    [ "$volname" = "Salvage $version" ] && pass "volume name is 'Salvage $version'" \
        || failed "volume name" "got '$volname'"
    entries="$(cd "$mountpoint" && ls -A | grep -vx '.fseventsd' | LC_ALL=C sort | tr '\n' ' ')"
    [ "$entries" = "Applications Salvage.app " ] && pass "top level is Salvage.app + Applications" \
        || failed "top level" "got '$entries'"
    [ -L "$mountpoint/Applications" ] && [ "$(readlink "$mountpoint/Applications")" = "/Applications" ] \
        && pass "Applications is a symlink to /Applications" || failed "Applications link" "not a symlink to /Applications"
    [ -x "$mountpoint/Salvage.app/Contents/MacOS/SalvageHelper" ] \
        && plutil -lint -s "$mountpoint/Salvage.app/Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist" \
        && pass "helper and launchd plist are inside the packaged app" || failed "packaged helper" "missing"
    if diff -r "$real_app" "$mountpoint/Salvage.app" > "$work/diff.txt" 2>&1; then
        pass "packaged Salvage.app is identical to the source"
    else
        failed "packaged app differs" "$(head -20 "$work/diff.txt")"
    fi
    hdiutil detach -quiet "$mountpoint" && pass "detached" || failed "detach" "hdiutil detach failed"
else
    failed "mount" "hdiutil attach failed"
fi

# A tampered download must fail verification.
cp "$dmg" "$work/tampered.dmg"
printf '\xff' | dd of="$work/tampered.dmg" bs=1 seek=4096 conv=notrunc 2>/dev/null
tampered_sum="$(awk '{print $1}' "$out/SHA256SUMS")  tampered.dmg"
if (cd "$work" && printf '%s\n' "$tampered_sum" | shasum -a 256 -c --strict - > /dev/null 2>&1); then
    failed "tampered image" "checksum still matched"
else
    pass "a modified DMG fails the checksum"
fi

if [ "$status" -eq 0 ]; then echo "All package-release scenarios passed."; else echo "Some scenarios FAILED."; fi
exit "$status"
