#!/usr/bin/env bash
set -uo pipefail

# test-check-xcodeproj-sync.sh
#
# Automated coverage for scripts/check-xcodeproj-sync.sh. Every planted drift happens in a
# throwaway copy of the repository (a fresh git work tree in a temp dir), never in the real tree:
# the checker takes the root to check as its argument. Asserts that a clean copy passes, that each
# kind of drift fails and is named, and that the checker fails closed when the pinned xcodegen
# can't be used. Exits 0 only when every scenario behaves as expected.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$root/scripts/check-xcodeproj-sync.sh"
status=0

work="$(mktemp -d "${TMPDIR:-/tmp}/salvage-test-xcodeproj-sync.XXXXXX")" || exit 1
work="$(cd "$work" && pwd -P)" || exit 1
trap 'rm -rf "$work"' EXIT

# Fresh copy of the tracked (plus untracked, non-ignored) tree, as its own git work tree so the
# checker takes the same path it takes on a real checkout.
fresh_copy() {
    local dest="$work/copy"
    rm -rf "$dest"
    mkdir -p "$dest"
    (
        cd "$root" || exit 1
        git ls-files -z --cached --others --exclude-standard \
            | while IFS= read -r -d '' path; do
                if [ -e "$path" ] || [ -L "$path" ]; then printf '%s\0' "$path"; fi
            done \
            | cpio -0 -pdm --quiet "$dest" 2>&1
    ) || { echo "FAIL: could not copy the repository"; exit 1; }
    (cd "$dest" && git init -q && git add -A) || { echo "FAIL: could not init the copy"; exit 1; }
    printf '%s\n' "$dest"
}

assert_passes() {
    local label="$1" target="$2"
    local output exit_code
    output="$("$checker" "$target" 2>&1)"; exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "FAIL [$label]: expected exit 0, got $exit_code"
        echo "$output"
        status=1
        return
    fi
    echo "PASS [$label]: exited 0"
}

assert_fails() {
    local label="$1" target="$2" expect="$3"
    local output exit_code
    output="$("$checker" "$target" 2>&1)"; exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "FAIL [$label]: expected non-zero exit, got 0"
        echo "$output"
        status=1
        return
    fi
    if ! printf '%s\n' "$output" | grep -qF -- "$expect"; then
        echo "FAIL [$label]: expected output to contain: $expect"
        echo "$output"
        status=1
        return
    fi
    echo "PASS [$label]: exited non-zero and named the problem"
}

drift_message="Salvage.xcodeproj is out of sync with project.yml"

echo "=== Scenario: the real repository is in sync ==="
assert_passes "real repository" "$root"

echo
echo "=== Scenario: a clean copy is in sync ==="
copy="$(fresh_copy)"
assert_passes "clean copy" "$copy"

echo
echo "=== Scenario: hand-edited project.pbxproj (planted drift) ==="
copy="$(fresh_copy)"
pbxproj="$copy/Salvage.xcodeproj/project.pbxproj"
# Change a value xcodegen derives from project.yml, as a hand edit in Xcode would.
sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 14.0;/MACOSX_DEPLOYMENT_TARGET = 13.0;/' "$pbxproj"
if ! grep -q 'MACOSX_DEPLOYMENT_TARGET = 13.0;' "$pbxproj"; then
    echo "FAIL [pbxproj drift]: could not plant the drift (pattern not found)"; status=1
else
    assert_fails "pbxproj drift" "$copy" "$drift_message"
fi

echo
echo "=== Scenario: project.yml changed without regenerating ==="
copy="$(fresh_copy)"
printf '\nsettings:\n  base:\n    SALVAGE_SYNC_SELF_TEST: "1"\n' >> "$copy/project.yml"
assert_fails "project.yml drift" "$copy" "$drift_message"

echo
echo "=== Scenario: a new source file the committed project doesn't list ==="
copy="$(fresh_copy)"
echo "// planted by test-check-xcodeproj-sync.sh" > "$copy/Salvage/__SyncSelfTestNewFile.swift"
assert_fails "untracked new source file" "$copy" "$drift_message"

echo
echo "=== Scenario: a stale extra file inside Salvage.xcodeproj ==="
copy="$(fresh_copy)"
scheme_dir="$copy/Salvage.xcodeproj/xcshareddata/xcschemes"
mkdir -p "$scheme_dir"
cp "$(find "$scheme_dir" -name '*.xcscheme' | head -n 1)" "$scheme_dir/StaleSelfTest.xcscheme" 2>/dev/null \
    || echo '<Scheme/>' > "$scheme_dir/StaleSelfTest.xcscheme"
assert_fails "stale extra scheme" "$copy" "Only in <committed>/Salvage.xcodeproj/xcshareddata/xcschemes: StaleSelfTest.xcscheme"

echo
echo "=== Scenario: empty directories Xcode leaves inside the project are not drift ==="
copy="$(fresh_copy)"
mkdir -p "$copy/Salvage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration"
assert_passes "empty Xcode-created directories" "$copy"

echo
echo "=== Scenario: a missing committed project fails closed ==="
copy="$(fresh_copy)"
rm -rf "$copy/Salvage.xcodeproj"
assert_fails "missing Salvage.xcodeproj" "$copy" "Salvage.xcodeproj not found"

echo
echo "=== Scenario: xcodegen not installed fails closed ==="
copy="$(fresh_copy)"
output="$(XCODEGEN="$work/no-such-xcodegen" "$checker" "$copy" 2>&1)"; exit_code=$?
if [ "$exit_code" -ne 0 ] && printf '%s\n' "$output" | grep -qF "xcodegen not found"; then
    echo "PASS [xcodegen missing]: exited non-zero and named the problem"
else
    echo "FAIL [xcodegen missing]: exit $exit_code"; echo "$output"; status=1
fi

echo
echo "=== Scenario: an unpinned xcodegen version fails closed ==="
fake="$work/fake-xcodegen"
printf '#!/bin/sh\necho "Version: 0.0.1"\n' > "$fake"; chmod +x "$fake"
output="$(XCODEGEN="$fake" "$checker" "$copy" 2>&1)"; exit_code=$?
if [ "$exit_code" -ne 0 ] && printf '%s\n' "$output" | grep -qF "but 2." && printf '%s\n' "$output" | grep -qF "is pinned"; then
    echo "PASS [wrong xcodegen version]: exited non-zero and named the problem"
else
    echo "FAIL [wrong xcodegen version]: exit $exit_code"; echo "$output"; status=1
fi

echo
echo "=== Post-condition: the real repository was not touched ==="
if [ -n "$(git -C "$root" status --porcelain -- Salvage.xcodeproj project.yml Salvage)" ]; then
    echo "FAIL [real tree untouched]: git reports changes under Salvage.xcodeproj, project.yml or Salvage/"
    status=1
else
    echo "PASS [real tree untouched]"
fi

echo
if [ "$status" -ne 0 ]; then
    echo "test-check-xcodeproj-sync.sh: FAILED"
else
    echo "test-check-xcodeproj-sync.sh: PASSED"
fi
exit "$status"
