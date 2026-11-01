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
echo "=== Step 3: SalvageCore's transitive dependency graph, with real local SwiftPM packages ==="
# A temporary copy of SalvageCore whose Package.swift gains a local path dependency, plus small
# throwaway packages, all under a temp dir -- the real SalvageCore is never edited. The checker's
# step 3 is pointed at the copy through SALVAGE_CORE_PACKAGE_PATH. The planted package names are
# deliberately innocuous ("Harmless", "Deeper"), so only a check that looks inside the
# dependencies -- not one matching names -- can catch them.
#
# Must work with no network: every dependency is a local path, git may only use the file
# protocol, and the proxies point at a closed port, so an attempted fetch fails instead of
# silently reaching the internet. The run must also leave no fetched repository behind.
step3_tmp="$(mktemp -d "${TMPDIR:-/tmp}/salvage-test-core-boundary.XXXXXX")"
step3_tmp="$(cd "$step3_tmp" && pwd -P)"
trap 'cleanup; rm -rf "$step3_tmp"' EXIT

# make_package DIR NAME SOURCE [DEPENDENCY_PATH]
make_package() {
    local dir="$1" name="$2" source="$3" dependency="${4:-}"
    local deps="" target_deps=""
    if [ -n "$dependency" ]; then
        local dep_name
        dep_name="$(basename "$dependency")"
        deps="dependencies: [.package(path: \"$dependency\")],"
        target_deps="dependencies: [.product(name: \"$dep_name\", package: \"$(printf '%s' "$dep_name" | tr '[:upper:]' '[:lower:]')\")],"
    fi
    mkdir -p "$dir/Sources/$name"
    cat > "$dir/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "$name",
    platforms: [.macOS(.v14)],
    products: [.library(name: "$name", targets: ["$name"])],
    $deps
    targets: [.target(name: "$name", $target_deps)]
)
MANIFEST
    printf '%s\n' "$source" > "$dir/Sources/$name/$name.swift"
}

# core_copy_with_dependency DEPENDENCY_PATH -> prints the copy's path
core_copy_with_dependency() {
    local dependency="$1" copy="$step3_tmp/SalvageCore-$RANDOM$RANDOM"
    mkdir -p "$copy"
    cp -R SalvageCore/Package.swift SalvageCore/Sources SalvageCore/Tests "$copy/"
    local dep_name
    dep_name="$(basename "$dependency")"
    # Add the package-level dependency and make the SalvageCore target use its product. Values go
    # through the environment so no path character needs escaping for perl.
    DEP_PATH="$dependency" DEP_NAME="$dep_name" DEP_ID="$(printf '%s' "$dep_name" | tr '[:upper:]' '[:lower:]')" \
        perl -0pi -e 's/\n    targets: \[/\n    dependencies: [.package(path: "$ENV{DEP_PATH}")],\n    targets: [/;
                      s/\.target\(\n(\s+)name: "SalvageCore",\n/.target(\n$1name: "SalvageCore",\n$1dependencies: [.product(name: "$ENV{DEP_NAME}", package: "$ENV{DEP_ID}")],\n/' \
        "$copy/Package.swift"
    if ! grep -q "package(path: \"$dependency\")" "$copy/Package.swift" || ! grep -q "product(name: \"$dep_name\"" "$copy/Package.swift"; then
        echo "could not add $dependency to the SalvageCore copy's Package.swift" >&2
        return 1
    fi
    printf '%s\n' "$copy"
}

run_offline_checker() {
    local core_copy="$1"
    SALVAGE_CORE_PACKAGE_PATH="$core_copy" GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 \
        HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 \
        http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 \
        "$checker" 2>&1
}

assert_step3() {
    local label="$1" core_copy="$2" expect_fail="$3" expect_grep="${4:-}"
    if [ -z "$core_copy" ]; then
        echo "FAIL [$label]: could not build the SalvageCore copy"; status=1; return
    fi
    local output exit_code
    output="$(run_offline_checker "$core_copy")"; exit_code=$?
    # SwiftPM creates these directories empty even for local-only graphs; anything inside them
    # means a repository was fetched.
    if [ -n "$(find "$core_copy/.build/repositories" "$core_copy/.build/checkouts" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        echo "FAIL [$label]: the checker fetched a repository; it must work offline from local paths"
        status=1; return
    fi
    if ! printf '%s\n' "$output" | grep -qF "Harmless"; then
        echo "FAIL [$label]: step 3 did not resolve the planted dependency (output never names it)"
        echo "$output"; status=1; return
    fi
    if [ "$expect_fail" = "fail" ]; then
        if [ "$exit_code" -eq 0 ]; then
            echo "FAIL [$label]: expected non-zero exit, got 0"; echo "$output"; status=1; return
        fi
        if ! printf '%s\n' "$output" | grep -qF "a package in SalvageCore's dependency graph requires a forbidden platform framework" \
            || ! printf '%s\n' "$output" | grep -qF -- "$expect_grep"; then
            echo "FAIL [$label]: expected the step-3 violation naming: $expect_grep"; echo "$output"; status=1; return
        fi
        echo "PASS [$label]: exited non-zero and named the violation"
    else
        if [ "$exit_code" -ne 0 ]; then
            echo "FAIL [$label]: expected exit 0, got $exit_code"; echo "$output"; status=1; return
        fi
        echo "PASS [$label]: exited 0"
    fi
}

echo
echo "--- A clean local dependency (Foundation only) passes ---"
make_package "$step3_tmp/clean/Harmless" Harmless 'import Foundation
public func harmless() -> Int { 1 }'
assert_step3 "clean local dependency" "$(core_copy_with_dependency "$step3_tmp/clean/Harmless")" pass

echo
echo "--- A direct local dependency importing AppKit fails ---"
make_package "$step3_tmp/direct/Harmless" Harmless 'import AppKit
public func harmless() -> NSColor { .red }'
assert_step3 "direct dependency imports AppKit" "$(core_copy_with_dependency "$step3_tmp/direct/Harmless")" fail \
    "$step3_tmp/direct/Harmless/Sources/Harmless/Harmless.swift"

echo
echo "--- A transitive dependency (Harmless -> Deeper) importing SwiftUI behind an attribute fails ---"
make_package "$step3_tmp/transitive/Deeper" Deeper '@preconcurrency import SwiftUI
public struct Deeper {}'
make_package "$step3_tmp/transitive/Harmless" Harmless 'import Deeper
public func harmless() {}' "$step3_tmp/transitive/Deeper"
assert_step3 "transitive dependency imports SwiftUI" "$(core_copy_with_dependency "$step3_tmp/transitive/Harmless")" fail \
    "$step3_tmp/transitive/Deeper/Sources/Deeper/Deeper.swift"

echo
echo "--- A dependency whose module map links IOKit fails ---"
make_package "$step3_tmp/modulemap/Harmless" Harmless 'import Foundation
public func harmless() {}'
mkdir -p "$step3_tmp/modulemap/Harmless/Sources/Harmless/include"
printf 'module HarmlessShim {\n    link framework "IOKit"\n}\n' > "$step3_tmp/modulemap/Harmless/Sources/Harmless/include/module.modulemap"
assert_step3 "dependency module map links IOKit" "$(core_copy_with_dependency "$step3_tmp/modulemap/Harmless")" fail \
    "module.modulemap"

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
