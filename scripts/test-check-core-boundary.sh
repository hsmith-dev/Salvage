#!/usr/bin/env bash
set -uo pipefail

# test-check-core-boundary.sh
#
# Automated, repeatable coverage for scripts/check-core-boundary.sh against the I/O & Edge-Case
# Matrix in spec-1-1-project-foundation-trustworthy-module-scaffold.md. Creates temporary
# violation files inside the real source tree (the checker is not parameterized to a target
# directory), asserts the checker's exit code and output, then always removes them -- even on
# failure or interruption -- via trap.
#
# Exit 0 only when every scenario below behaves as the matrix specifies.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

checker="./scripts/check-core-boundary.sh"
status=0

core_violation_file="SalvageCore/Sources/SalvageCore/__TestForbiddenImport.swift"
app_violation_file="Salvage/__TestDiskArbitrationLeak.swift"
spike_harness_file="scripts/spike-raw-device-access/Sources/spike-raw-device-access/__TestDiskArbitrationImport.swift"

cleanup() {
    rm -f "$core_violation_file" "$app_violation_file" "$spike_harness_file"
}
trap cleanup EXIT

assert_fails() {
    local label="$1"
    local expect_grep="$2"
    local output
    output="$("$checker" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "FAIL [$label]: expected non-zero exit, got 0"
        status=1
        return
    fi
    if ! printf '%s\n' "$output" | grep -qF "$expect_grep"; then
        echo "FAIL [$label]: expected output to name the violation (looking for: $expect_grep)"
        status=1
        return
    fi
    echo "PASS [$label]: exited non-zero and named the violation"
}

assert_passes() {
    local label="$1"
    local output
    output="$("$checker" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "FAIL [$label]: expected exit 0, got $exit_code"
        echo "$output"
        status=1
        return
    fi
    echo "PASS [$label]: exited 0 on a clean tree"
}

echo "=== Scenario: clean scaffold (matrix row 'Clean scaffold') ==="
cleanup
assert_passes "clean scaffold"

echo
echo "=== Scenario: forbidden import in SalvageCore (matrix row 1) ==="
echo "import SwiftUI" > "$core_violation_file"
assert_fails "forbidden import in SalvageCore" "$core_violation_file"
rm -f "$core_violation_file"

echo
echo "=== Scenario: DiskArbitration imported outside SalvageDiskIO (matrix row 2) ==="
echo "import DiskArbitration" > "$app_violation_file"
assert_fails "DiskArbitration leak" "$app_violation_file"
rm -f "$app_violation_file"

echo
echo "=== Scenario: DiskArbitration imported inside the spike-raw-device-access exclusion (must still pass) ==="
# scripts/spike-raw-device-access/ is a deliberate, narrow exclusion from check #2 (it's
# disposable spike tooling, never wired into SalvageDiskIO/SalvageCore/Salvage -- see that
# script's comments). This asserts the exclusion actually works for a real import there.
echo "import DiskArbitration" > "$spike_harness_file"
assert_passes "DiskArbitration import inside the spike-raw-device-access exclusion"
rm -f "$spike_harness_file"

echo
echo "=== Scenario: DiskArbitration imported just outside the exclusion must still be caught ==="
# Guards against the exclusion pattern being (or becoming, via a future typo) broader than
# intended -- e.g. a bare 'scripts/' prefix match would also swallow this file, which sits
# directly under scripts/ rather than under scripts/spike-raw-device-access/.
scripts_root_violation_file="scripts/__TestDiskArbitrationLeak.swift"
echo "import DiskArbitration" > "$scripts_root_violation_file"
assert_fails "DiskArbitration leak just outside the spike-harness exclusion" "$scripts_root_violation_file"
rm -f "$scripts_root_violation_file"

echo
echo "=== Post-condition: tree is clean again after all injected scenarios ==="
assert_passes "clean after teardown"

echo
if [ "$status" -ne 0 ]; then
    echo "test-check-core-boundary.sh: FAILED"
else
    echo "test-check-core-boundary.sh: PASSED"
fi
exit "$status"
