#!/usr/bin/env bash
set -uo pipefail

# check-no-network.sh
#
# Enforces Architecture AD-12 / FR-18 ("zero network activity apart from a manual, user-initiated
# Check for Updates"):
#
#   1. No network-capable API may appear in any .swift file under Salvage/, SalvageCore/,
#      SalvageDiskIO/, SalvageHelper/ (the privileged read-only helper, AD-13) or scripts/,
#      except the one designated update-check file, Salvage/Updates/UpdateChecker.swift.
#      XPC (xpc_connection_*, NSXPCConnection) is local IPC, not network, and is allowed; the
#      patterns below don't match it.
#   2. No Package.swift may declare a remote dependency (`.package(url:`).
#
# Usage: check-no-network.sh [repo-root]
#   The optional argument lets scripts/test-check-no-network.sh run this checker against a
#   temporary copy of the tree; by default it checks the repository this script lives in.
#
# The pattern list below exists only for this scanner. Only .swift files are searched, so this
# script (and its self-test) never match their own pattern lists.
#
# Exits non-zero and names each offending file, line and pattern on any violation; exits 0 only
# when both checks pass.

if [ "$#" -ge 1 ]; then
    root="$(cd "$1" && pwd)" || exit 1
else
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$root" || exit 1

status=0
scan_dirs=(Salvage SalvageCore SalvageDiskIO SalvageHelper scripts)
allowed_file="Salvage/Updates/UpdateChecker.swift"

# Extended regular expressions, one per forbidden API. `socket(` and `connect(` are anchored on a
# word boundary so names such as `disconnect(` don't trip the check.
patterns=(
    'URLSession'
    'URLRequest'
    'NSURLConnection'
    'import[[:space:]]+Network\b'
    'NWConnection'
    'NWListener'
    'NWPathMonitor'
    'CFSocket'
    'CFStreamCreatePairWithSocket'
    '\bsocket[[:space:]]*\('
    '\bconnect[[:space:]]*\('
    'getaddrinfo'
    'WKWebView'
    'import[[:space:]]+WebKit\b'
)

existing_dirs=()
for dir in "${scan_dirs[@]}"; do
    [ -d "$dir" ] && existing_dirs+=("$dir")
done

swift_files() {
    [ "${#existing_dirs[@]}" -eq 0 ] && return 0
    find "${existing_dirs[@]}" \( -name .build -o -name .git -o -name DerivedData \) -prune -o -type f -name '*.swift' -print
}

echo "== [1/2] Network APIs only in $allowed_file =="
found=0
while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ "$file" = "$allowed_file" ] && continue
    for pattern in "${patterns[@]}"; do
        hits="$(grep -nE "$pattern" "$file" 2>/dev/null)"
        if [ -n "$hits" ]; then
            while IFS= read -r hit; do
                echo "VIOLATION: $file:$hit  (matches: $pattern)"
            done <<< "$hits"
            found=1
        fi
    done
done < <(swift_files)
if [ "$found" -ne 0 ]; then
    echo "Network-capable APIs may only be used in $allowed_file (the user-initiated Check for Updates)."
    status=1
else
    echo "OK: no network-capable API outside $allowed_file"
fi

echo
echo "== [2/2] No Package.swift declares a remote dependency =="
remote_found=0
while IFS= read -r manifest; do
    [ -z "$manifest" ] && continue
    hits="$(grep -nE '\.package[[:space:]]*\([[:space:]]*url[[:space:]]*:' "$manifest" 2>/dev/null)"
    if [ -n "$hits" ]; then
        while IFS= read -r hit; do
            echo "VIOLATION: $manifest:$hit  (remote package dependency)"
        done <<< "$hits"
        remote_found=1
    fi
# Hidden directories (.build, .claude worktrees, VCS metadata, ...) and DerivedData are skipped.
done < <(find . -mindepth 1 \( -name '.*' -o -name DerivedData \) -prune -o -type f -name 'Package.swift' -print | sed 's|^\./||')
if [ "$remote_found" -ne 0 ]; then
    status=1
else
    echo "OK: no remote package dependencies"
fi

echo
if [ "$status" -ne 0 ]; then
    echo "check-no-network.sh: FAILED -- see VIOLATION lines above"
else
    echo "check-no-network.sh: PASSED"
fi
exit "$status"
