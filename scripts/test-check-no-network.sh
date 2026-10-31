#!/usr/bin/env bash
set -uo pipefail

# test-check-no-network.sh
#
# Automated, repeatable coverage for scripts/check-no-network.sh against the I/O & Edge-Case
# Matrix in spec-1-11-verify-the-app-s-privacy-guarantees-yourself.md ("Stray network API in
# Core -> build fails, naming the file"). Unlike test-check-core-boundary.sh, violations are
# planted in a temporary copy of the source tree (the checker takes the root to scan as its
# argument), so the real tree is never touched. The copy is always removed via trap.
#
# Exit 0 only when every scenario below behaves as expected.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

checker="$root/scripts/check-no-network.sh"
status=0

work="$(mktemp -d "${TMPDIR:-/tmp}/check-no-network-test.XXXXXX")" || exit 1
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

copy="$work/tree"

fresh_copy() {
    rm -rf "$copy"
    mkdir -p "$copy"
    local dir
    for dir in Salvage SalvageCore SalvageDiskIO SalvageHelper scripts; do
        [ -d "$dir" ] && rsync -a --exclude .build --exclude DerivedData "$dir" "$copy/"
    done
}

assert_fails() {
    local label="$1"
    local expect_grep="$2"
    local output
    output="$("$checker" "$copy" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "FAIL [$label]: expected non-zero exit, got 0"
        status=1
        return
    fi
    if ! printf '%s\n' "$output" | grep -qF "$expect_grep"; then
        echo "FAIL [$label]: expected output to name the violation (looking for: $expect_grep)"
        echo "$output"
        status=1
        return
    fi
    echo "PASS [$label]: exited non-zero and named the violation"
}

assert_passes() {
    local label="$1"
    shift
    local output
    output="$("$checker" "$@" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "FAIL [$label]: expected exit 0, got $exit_code"
        echo "$output"
        status=1
        return
    fi
    echo "PASS [$label]: exited 0"
}

# plant_violation <label> <relative file> <line of Swift> -- writes the file into a fresh copy and
# asserts the checker fails naming that file.
plant_violation() {
    local label="$1" file="$2" line="$3"
    fresh_copy
    mkdir -p "$copy/$(dirname "$file")"
    printf '%s\n' "$line" > "$copy/$file"
    assert_fails "$label" "$file"
}

echo "=== Scenario: the real tree is clean ==="
assert_passes "real tree"

echo
echo "=== Scenario: clean temporary copy (designated UpdateChecker.swift is allowed) ==="
fresh_copy
assert_passes "clean copy" "$copy"

echo
echo "=== Scenario: stray network APIs outside the designated file ==="
plant_violation "URLSession in SalvageCore" \
    "SalvageCore/Sources/SalvageCore/__TestStrayNetwork.swift" "let s = URLSession.shared"
plant_violation "URLRequest in the app target" \
    "Salvage/Views/__TestStrayNetwork.swift" "let r = URLRequest(url: u)"
plant_violation "import Network in SalvageDiskIO" \
    "SalvageDiskIO/Sources/SalvageDiskIO/__TestStrayNetwork.swift" "import Network"
plant_violation "NWPathMonitor in SalvageDiskIO" \
    "SalvageDiskIO/Sources/SalvageDiskIO/__TestStrayNetwork.swift" "let m = NWPathMonitor()"
plant_violation "NWConnection in SalvageDiskIO" \
    "SalvageDiskIO/Sources/SalvageDiskIO/__TestStrayNetwork.swift" "let c = NWConnection(host: h, port: p, using: .tcp)"
plant_violation "NWListener in the app target" \
    "Salvage/__TestStrayNetwork.swift" "let l = try NWListener(using: .tcp)"
plant_violation "CFStreamCreatePairWithSocket in SalvageCore" \
    "SalvageCore/Sources/SalvageCore/__TestStrayNetwork.swift" "CFStreamCreatePairWithSocket(nil, fd, &r, &w)"
plant_violation "BSD socket( in the spike harness" \
    "scripts/spike-raw-device-access/Sources/spike-raw-device-access/__TestStrayNetwork.swift" "let fd = socket(AF_INET, SOCK_STREAM, 0)"
plant_violation "connect( in scripts/" \
    "scripts/__TestStrayNetwork.swift" "_ = connect(fd, addr, len)"
plant_violation "getaddrinfo in SalvageCore tests" \
    "SalvageCore/Tests/SalvageCoreTests/__TestStrayNetwork.swift" "getaddrinfo(host, nil, &hints, &res)"
plant_violation "WKWebView in the app target" \
    "Salvage/__TestStrayNetwork.swift" "let w = WKWebView()"
plant_violation "import WebKit in the app target" \
    "Salvage/__TestStrayNetwork.swift" "import WebKit"
plant_violation "CFSocket in SalvageCore" \
    "SalvageCore/Sources/SalvageCore/__TestStrayNetwork.swift" "let s: CFSocket? = nil"
plant_violation "NSURLConnection in the app target" \
    "Salvage/__TestStrayNetwork.swift" "NSURLConnection.canHandle(r)"
plant_violation "BSD socket( in the privileged helper" \
    "SalvageHelper/__TestStrayNetwork.swift" "let fd = socket(AF_INET, SOCK_STREAM, 0)"
plant_violation "URLSession in the privileged helper" \
    "SalvageHelper/__TestStrayNetwork.swift" "let s = URLSession.shared"

echo
echo "=== Scenario: the exclusion is the exact designated path, not a file name ==="
plant_violation "a second UpdateChecker.swift in SalvageCore" \
    "SalvageCore/Sources/SalvageCore/UpdateChecker.swift" "let s = URLSession.shared"
plant_violation "UpdateChecker.swift directly under Salvage/" \
    "Salvage/UpdateChecker.swift" "let s = URLSession.shared"

echo
echo "=== Scenario: remote package dependency ==="
fresh_copy
manifest="SalvageCore/Package.swift"
printf '%s\n' '// .package(url: "https://example.com/dep.git", from: "1.0.0"),' >> "$copy/$manifest"
assert_fails "remote dependency in SalvageCore/Package.swift" "$manifest"

echo
echo "=== Scenario: no false positives ==="
fresh_copy
printf '%s\n' "session.disconnect(reason)" "let socketCount = 0" > "$copy/SalvageCore/Sources/SalvageCore/__TestLookalikes.swift"
assert_passes "disconnect( and socketCount are not network calls" "$copy"
fresh_copy
mkdir -p "$copy/SalvageHelper"
printf '%s\n' \
    "let l = xpc_connection_create_mach_service(name, q, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))" \
    "xpc_connection_set_peer_code_signing_requirement(peer, requirement)" \
    "xpc_connection_send_message_with_reply(connection, message, queue) { _ in }" \
    "let c = NSXPCConnection(machServiceName: name, options: .privileged)" \
    "xpc_connection_cancel(peer)" > "$copy/SalvageHelper/__TestLocalIPC.swift"
assert_passes "XPC local IPC in the helper is not network" "$copy"
fresh_copy
mkdir -p "$copy/SalvageCore/.build/checkouts"
printf '%s\n' "let s = URLSession.shared" > "$copy/SalvageCore/.build/checkouts/__TestBuildArtifact.swift"
assert_passes "build products under .build are ignored" "$copy"

echo
echo "=== Post-condition: the real tree is still clean ==="
assert_passes "real tree after scenarios"

echo
if [ "$status" -ne 0 ]; then
    echo "test-check-no-network.sh: FAILED"
else
    echo "test-check-no-network.sh: PASSED"
fi
exit "$status"
