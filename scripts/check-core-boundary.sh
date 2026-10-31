#!/usr/bin/env bash
set -uo pipefail

# check-core-boundary.sh
#
# Enforces Architecture AD-9 ("Core/DiskIO boundary is CI-enforced, not just reviewed"):
#
#   1. SalvageCore must never import AppKit, SwiftUI, or IOKit.
#   2. DiskArbitration must never be imported outside SalvageDiskIO (i.e. it is also forbidden
#      inside SalvageCore and the Salvage app target).
#   3. SalvageCore's resolved dependency graph must never pull in a transitive dependency that
#      itself requires one of those same non-portable platform frameworks.
#
# One deliberate, narrow exclusion from check #2: `scripts/spike-raw-device-access/`, the
# disposable SwiftPM CLI harness built for Story 1.2's FDA/raw-device-access spike (see
# _bmad-output/implementation-artifacts/spec-1-2-full-disk-access-raw-device-access-spike.md).
# Its Boundaries & Constraints explicitly keep that harness outside the shipping app and outside
# SalvageDiskIO/SalvageCore/Salvage entirely -- AD-1/AD-9's "exclusive owner" rule binds the
# three hexagonal modules, not standalone spike tooling never wired into them. If the harness is
# ever promoted into the shipping app, it must move under SalvageDiskIO and this exclusion must
# be removed.
#
# Exits non-zero and names the offending file/import/dependency on any violation; exits 0 only
# when every check passes cleanly. Intended to be run both locally and as a CI step
# (.github/workflows/ci.yml).

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

status=0

# Matches a bare `import Foo` as well as an attribute-prefixed one (`@testable import Foo`,
# `@_implementationOnly import Foo`, `@preconcurrency(Foo) import Foo`, stacked attributes, ...)
# so an import can't dodge these checks just by adding an attribute in front of it.
import_prefix='^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*import[[:space:]]+'

echo "== [1/3] SalvageCore must not import AppKit, SwiftUI, or IOKit =="
if [ -d SalvageCore ]; then
    violations="$(grep -rnE --exclude-dir=.build --exclude-dir=.git "${import_prefix}(AppKit|SwiftUI|IOKit)\\b" SalvageCore 2>/dev/null)"
    if [ -n "$violations" ]; then
        echo "VIOLATION: forbidden import found under SalvageCore:"
        echo "$violations"
        status=1
    else
        echo "OK: no AppKit/SwiftUI/IOKit imports under SalvageCore (Sources or Tests)"
    fi
else
    echo "OK: SalvageCore does not exist yet (nothing to check)"
fi

echo
echo "== [2/3] DiskArbitration must only be imported inside SalvageDiskIO =="
all_disk_arbitration_imports="$(grep -rnE --exclude-dir=.git --exclude-dir=.claude --exclude-dir=.build --exclude-dir=DerivedData --include='*.swift' "${import_prefix}DiskArbitration\\b" . 2>/dev/null)"
leaked="$(printf '%s\n' "$all_disk_arbitration_imports" | grep -v '^\./SalvageDiskIO/' | grep -v '^\./scripts/spike-raw-device-access/' | grep -v '^$')"
if [ -n "$leaked" ]; then
    echo "VIOLATION: DiskArbitration imported outside SalvageDiskIO:"
    echo "$leaked"
    status=1
else
    echo "OK: DiskArbitration is only imported (if at all) within SalvageDiskIO"
fi

echo
echo "== [3/3] SalvageCore's dependency graph must not leak a non-portable platform framework =="
# Mirrors AD-9's Rule text verbatim: AppKit, SwiftUI, IOKit, DiskArbitration are the forbidden
# frameworks. A direct source-tree grep (steps 1-2) alone would miss a third-party SwiftPM
# dependency silently reintroducing one of these transitively.
forbidden_pattern='AppKit|SwiftUI|IOKit|DiskArbitration'
if [ -f SalvageCore/Package.swift ]; then
    deps_output="$(swift package --package-path SalvageCore show-dependencies --format text 2>&1)"
    deps_status=$?
    echo "$deps_output"
    if [ "$deps_status" -ne 0 ]; then
        echo "VIOLATION: failed to resolve SalvageCore's dependency graph (see output above)"
        status=1
    else
        leaked_deps="$(printf '%s\n' "$deps_output" | grep -iE "$forbidden_pattern")"
        if [ -n "$leaked_deps" ]; then
            echo "VIOLATION: SalvageCore's dependency graph references a forbidden platform framework:"
            echo "$leaked_deps"
            status=1
        else
            echo "OK: SalvageCore's dependency graph contains no forbidden platform frameworks"
        fi
    fi
else
    echo "VIOLATION: SalvageCore/Package.swift not found -- cannot resolve dependency graph"
    status=1
fi

echo
if [ "$status" -ne 0 ]; then
    echo "check-core-boundary.sh: FAILED -- see VIOLATION lines above"
else
    echo "check-core-boundary.sh: PASSED"
fi

exit "$status"
