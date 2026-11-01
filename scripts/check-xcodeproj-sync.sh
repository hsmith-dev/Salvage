#!/usr/bin/env bash
set -uo pipefail

# check-xcodeproj-sync.sh [ROOT]
#
# Fails when the committed Salvage.xcodeproj differs from what `xcodegen generate` produces from
# project.yml (its source of truth). The project is regenerated into a temporary copy of the tree
# (never in place), and the generated Salvage.xcodeproj is compared with the committed one using
# `diff -r`, so a stale, missing or extra file (e.g. a scheme) is caught, not just pbxproj edits.
#
# ROOT defaults to the repository this script lives in. In a git work tree, the copy holds the
# tracked files plus untracked, non-ignored ones (what xcodegen's source globs would see on a clean
# checkout plus anything about to be committed); outside git, everything except build output.
#
# The xcodegen binary is $XCODEGEN if set, else `xcodegen` on PATH. Its version must equal
# PINNED_XCODEGEN_VERSION below -- the same version CI installs (.github/workflows/ci.yml) --
# because different xcodegen versions can emit different projects. Set
# SALVAGE_XCODEGEN_ANY_VERSION=1 to compare with another version anyway (a local convenience;
# CI never sets it). Exits non-zero, naming the problem, on drift or when the check can't run.

PINNED_XCODEGEN_VERSION="2.46.0"

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
root="$(cd "$root" 2>/dev/null && pwd)" || { echo "check-xcodeproj-sync.sh: FAILED -- no such directory: ${1:-}"; exit 1; }
project_name="Salvage.xcodeproj"

fail() {
    echo "VIOLATION: $1"
    echo "check-xcodeproj-sync.sh: FAILED"
    exit 1
}

[ -f "$root/project.yml" ] || fail "$root/project.yml not found"
[ -d "$root/$project_name" ] || fail "$root/$project_name not found (it must be committed alongside project.yml)"

xcodegen="${XCODEGEN:-xcodegen}"
command -v "$xcodegen" >/dev/null 2>&1 || fail "xcodegen not found ('$xcodegen'); install xcodegen $PINNED_XCODEGEN_VERSION or set XCODEGEN"
version_output="$("$xcodegen" --version 2>&1)" || fail "'$xcodegen --version' failed: $version_output"
version="$(printf '%s\n' "$version_output" | sed -n 's/^Version: *//p' | head -n 1)"
if [ "$version" != "$PINNED_XCODEGEN_VERSION" ]; then
    if [ "${SALVAGE_XCODEGEN_ANY_VERSION:-}" = "1" ]; then
        echo "WARNING: xcodegen is '$version', not the pinned $PINNED_XCODEGEN_VERSION; output may differ for that reason alone"
    else
        fail "xcodegen is '$version' but $PINNED_XCODEGEN_VERSION is pinned (set SALVAGE_XCODEGEN_ANY_VERSION=1 to compare anyway)"
    fi
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/salvage-xcodeproj-sync.XXXXXX")" || fail "could not create a temporary directory"
# Physical path: cpio refuses to extract through a symlink such as /var -> /private/var.
work="$(cd "$work" && pwd -P)" || fail "could not resolve the temporary directory"
trap 'rm -rf "$work"' EXIT
copy="$work/tree"
mkdir -p "$copy"

if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git -C "$root" rev-parse --show-toplevel)" = "$root" ]; then
    # Deleted-but-unstaged files are listed by ls-files yet absent on disk; skip those.
    (
        cd "$root" || exit 1
        git ls-files -z --cached --others --exclude-standard \
            | while IFS= read -r -d '' path; do
                if [ -e "$path" ] || [ -L "$path" ]; then printf '%s\0' "$path"; fi
            done \
            | cpio -0 -pdm --quiet "$copy" 2>&1
    ) || fail "could not copy the tree into $copy"
else
    (
        cd "$root" || exit 1
        find . \( -name .git -o -name .build -o -name DerivedData -o -name .claude \) -prune -o -print0 \
            | cpio -0 -pdm --quiet "$copy" 2>&1
    ) || fail "could not copy the tree into $copy"
fi

# Compare against the project as copied, not the live directory: in a git tree that is exactly
# the files git would commit, so empty directories Xcode leaves behind (e.g.
# project.xcworkspace/xcshareddata/swiftpm/configuration after a build) are not reported as drift.
# Then regenerate from scratch, with nothing stale left in the copy.
committed="$work/committed"
mkdir -p "$committed"
[ -d "$copy/$project_name" ] || fail "$project_name has no files git would commit"
mv "$copy/$project_name" "$committed/$project_name" || fail "could not set aside the committed $project_name"
gen_output="$(cd "$copy" && "$xcodegen" generate --spec project.yml --project . 2>&1)"
gen_status=$?
if [ "$gen_status" -ne 0 ]; then
    echo "$gen_output"
    fail "xcodegen generate failed (exit $gen_status)"
fi
[ -d "$copy/$project_name" ] || fail "xcodegen generate did not produce $project_name"

# xcodegen never writes user state; ignore any committed-but-ignored xcuserdata on both sides.
diff_output="$(diff -r -x xcuserdata "$committed/$project_name" "$copy/$project_name" 2>&1)"
diff_status=$?
if [ "$diff_status" -ne 0 ]; then
    printf '%s\n' "$diff_output" | sed -e "s#$copy/#<generated>/#g" -e "s#$committed/#<committed>/#g" | head -n 200
    fail "$project_name is out of sync with project.yml -- run 'xcodegen generate' (xcodegen $PINNED_XCODEGEN_VERSION) and commit the result"
fi

echo "OK: $project_name matches what xcodegen $version generates from project.yml"
echo "check-xcodeproj-sync.sh: PASSED"
exit 0
