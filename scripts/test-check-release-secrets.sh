#!/usr/bin/env bash
set -uo pipefail

# test-check-release-secrets.sh
#
# Automated coverage for scripts/check-release-secrets.sh, since that logic previously lived
# inline in release.yml with zero automated coverage (unlike check-core-boundary.sh, which has
# test-check-core-boundary.sh). Runs the checker with various subsets of the four required
# secrets unset, asserting exit code and that each missing name is named in the output.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

checker="./scripts/check-release-secrets.sh"
status=0

all_vars=(DEVELOPER_ID_APPLICATION_CERT_P12 DEVELOPER_ID_CERT_PASSWORD NOTARIZATION_API_KEY DEVELOPMENT_TEAM)

# run_checker <space-separated list of var names to set (others left unset)>
run_checker() {
    local set_vars=" $1 "
    local assignments=()
    local v
    for v in "${all_vars[@]}"; do
        if [[ "$set_vars" == *" $v "* ]]; then
            assignments+=("$v=dummy-value")
        fi
    done
    # The ${arr[@]+"${arr[@]}"} form (rather than plain "${assignments[@]}") avoids an "unbound
    # variable" error under `set -u` on bash 3.2 (macOS's default /bin/bash) when the array is
    # empty, e.g. the "all four missing" scenario.
    env -i PATH="$PATH" ${assignments[@]+"${assignments[@]}"} "$checker"
}

assert_fails_naming() {
    local label="$1"
    local set_vars="$2"
    shift 2
    local expected_missing=("$@")
    local output
    output="$(run_checker "$set_vars" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "FAIL [$label]: expected non-zero exit, got 0"
        status=1
        return
    fi
    local ok=1
    for name in "${expected_missing[@]}"; do
        if ! printf '%s\n' "$output" | grep -q "$name"; then
            echo "FAIL [$label]: expected output to name missing secret '$name', got:"
            echo "$output"
            ok=0
        fi
    done
    [ "$ok" -eq 1 ] && echo "PASS [$label]: exited non-zero and named: ${expected_missing[*]}"
    [ "$ok" -eq 1 ] || status=1
}

assert_passes() {
    local label="$1"
    local set_vars="$2"
    local output
    output="$(run_checker "$set_vars" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "FAIL [$label]: expected exit 0, got $exit_code"
        echo "$output"
        status=1
        return
    fi
    echo "PASS [$label]: exited 0 with all secrets present"
}

echo "=== Scenario: all four secrets present ==="
assert_passes "all present" "DEVELOPER_ID_APPLICATION_CERT_P12 DEVELOPER_ID_CERT_PASSWORD NOTARIZATION_API_KEY DEVELOPMENT_TEAM"

echo
echo "=== Scenario: all four secrets missing ==="
assert_fails_naming "all missing" "" \
    DEVELOPER_ID_APPLICATION_CERT_P12 DEVELOPER_ID_CERT_PASSWORD NOTARIZATION_API_KEY DEVELOPMENT_TEAM

echo
echo "=== Scenario: only NOTARIZATION_API_KEY missing ==="
assert_fails_naming "only NOTARIZATION_API_KEY missing" "DEVELOPER_ID_APPLICATION_CERT_P12 DEVELOPER_ID_CERT_PASSWORD DEVELOPMENT_TEAM" \
    NOTARIZATION_API_KEY

echo
echo "=== Scenario: only DEVELOPMENT_TEAM present (other three missing) ==="
assert_fails_naming "three missing" "DEVELOPMENT_TEAM" \
    DEVELOPER_ID_APPLICATION_CERT_P12 DEVELOPER_ID_CERT_PASSWORD NOTARIZATION_API_KEY

echo
if [ "$status" -ne 0 ]; then
    echo "test-check-release-secrets.sh: FAILED"
else
    echo "test-check-release-secrets.sh: PASSED"
fi
exit "$status"
