#!/usr/bin/env bash
# Salvage parser fuzzing (spec-tech-batch-6 §A).
#
#   ./scripts/fuzz-parsers.sh                 # 20,000 iterations per format, random seed, release build
#   ./scripts/fuzz-parsers.sh --smoke         # CI smoke test: 500 iterations per format, fixed seed
#   ./scripts/fuzz-parsers.sh --debug         # debug build instead of release (slower; same traps)
#   ./scripts/fuzz-parsers.sh --repro <file>  # replay one saved input
#
# Runs SalvageCoreTests' FuzzTests/fuzzParsers driver, which mutates small valid images (the
# synthetic test builders for FAT32, exFAT, NTFS, EXT2/4, APFS, HFS+, MBR and GPT layouts, plus
# real hdiutil images) and runs a full ScanSession over each through an in-memory reader. Every
# batch runs in a child process, so a trap is reported with its seed and iteration; scans that
# outlive their wall-clock budget are killed and reported as hangs. Crashing inputs, minimised
# inputs and reproducer commands are written under the output directory (crashes/*/README.txt),
# with summary.json beside them.
#
# Real seed images are created with hdiutil in a temp dir, attached at a private mount point
# (-nobrowse) only while populated, then detached and deleted. No sudo, no device is opened.
#
# Environment (all optional): SALVAGE_FUZZ_ITERATIONS, SALVAGE_FUZZ_SEED, SALVAGE_FUZZ_FORMATS,
# SALVAGE_FUZZ_JOBS, SALVAGE_FUZZ_BATCH, SALVAGE_FUZZ_DIR, SALVAGE_FUZZ_REAL_IMAGES=0,
# SALVAGE_FUZZ_HANG_BASE, SALVAGE_FUZZ_HANG_PER_MIB, SALVAGE_FUZZ_MINIMISE=0, SALVAGE_FUZZ_ALLOW.
# See the header of SalvageCore/Tests/SalvageCoreTests/FuzzTests.swift.
#
# Exit status: 0 when no crash or hang was found (other than SALVAGE_FUZZ_ALLOW'd ones), 1 otherwise.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$root/SalvageCore"
configuration=release
repro=""

while [ $# -gt 0 ]; do
    case "$1" in
        --smoke)
            export SALVAGE_FUZZ_ITERATIONS="${SALVAGE_FUZZ_ITERATIONS:-500}"
            export SALVAGE_FUZZ_SEED="${SALVAGE_FUZZ_SEED:-0x5a17a6e}"
            ;;
        --debug) configuration=debug ;;
        --release) configuration=release ;;
        --repro) shift; repro="${1:?--repro needs a file}" ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

export SALVAGE_FUZZ_ITERATIONS="${SALVAGE_FUZZ_ITERATIONS:-20000}"
export SALVAGE_FUZZ_SEED="${SALVAGE_FUZZ_SEED:-$(( (RANDOM << 30) ^ (RANDOM << 15) ^ RANDOM ))}"
export SALVAGE_FUZZ_DIR="${SALVAGE_FUZZ_DIR:-${TMPDIR:-/tmp}/salvage-fuzz-$SALVAGE_FUZZ_SEED}"

# Release builds need -enable-testing for the test target's @testable import.
build_flags=(-c "$configuration")
[ "$configuration" = release ] && build_flags+=(-Xswiftc -enable-testing)

if [ -n "$repro" ]; then
    SALVAGE_FUZZ_REPRO="$repro" swift test --package-path "$package" "${build_flags[@]}" --filter FuzzTests/fuzzReproduce
    exit $?
fi

echo "== fuzzing parsers: $SALVAGE_FUZZ_ITERATIONS iterations per format, seed $SALVAGE_FUZZ_SEED, $configuration build"
echo "== output: $SALVAGE_FUZZ_DIR"
swift build --package-path "$package" "${build_flags[@]}" --build-tests
status=0
SALVAGE_FUZZ=1 swift test --package-path "$package" "${build_flags[@]}" --skip-build --filter FuzzTests/fuzzParsers 2>&1 \
    | grep -E '^FUZZ|✘|error:|passed after|failed after' || true
# grep hides swift test's own exit status; the summary says whether anything was found.
summary="$SALVAGE_FUZZ_DIR/summary.json"
if [ ! -f "$summary" ]; then
    echo "fuzz run produced no summary ($summary)" >&2
    exit 1
fi
python3 - "$summary" <<'EOF' || status=1
import json, os, sys
summary = json.load(open(sys.argv[1]))
allowed = [s for s in os.environ.get("SALVAGE_FUZZ_ALLOW", "").split(",") if s]
bad = 0
for entry in summary["formats"]:
    for finding in entry["findings"]:
        known = any(a in finding["signature"] for a in allowed)
        bad += 0 if known else 1
        print(f'{"known " if known else ""}{finding["kind"]}: {entry["format"]} iteration {finding["iteration"]}: {finding["signature"]} ({finding["folder"]})')
print(f'{sum(e["iterations"] for e in summary["formats"])} iterations over {len(summary["formats"])} formats, seed {summary["seed"]}, {summary["elapsedSeconds"]:.0f}s')
sys.exit(1 if bad else 0)
EOF
exit $status
