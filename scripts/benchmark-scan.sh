#!/usr/bin/env bash
# Salvage performance benchmark (batch 5, item D). Release builds only.
#
#   ./scripts/benchmark-scan.sh            # exFAT + FAT32 scans/recovery, then results browser
#   ./scripts/benchmark-scan.sh scan       # only the image scans
#   ./scripts/benchmark-scan.sh results    # only the results-browser filter/sort benchmark
#
# Scans: builds 2 GB exFAT (GPT) and FAT32 (MBR) images with ~50k files in nested folders
# (10% deleted) through hdiutil in a temp dir, scans each detached image *file* with ScanSession,
# recovers every metadata-found file to a temp folder and checks a sample byte for byte. One
# `swift test` process per image, so peak RSS is per scan. Images are attached only while being
# populated (-nobrowse, private mount point), always detached, and deleted at the end unless
# SALVAGE_BENCHMARK_DIR is set (then the caller owns them; they are reused on the next run).
# No sudo, no device nodes are opened.
#
# Results browser: builds ResultsViewModel.swift (the app's file, unmodified) into a throwaway
# release executable against SalvageCore and times row building, dashboard aggregates, and
# filter/sort over 100k rows. Each query is also run through a verbatim copy of the pre-batch-5
# `apply` ("before_ms"), and the script fails unless both return the same rows in the same order.
#
# Environment: SALVAGE_BENCHMARK_FILES (50000), SALVAGE_BENCHMARK_SIZE_MIB (2048),
# SALVAGE_BENCHMARK_ROWS (100000), SALVAGE_BENCHMARK_DIR, SALVAGE_BENCHMARK_REPORT (JSON lines),
# SALVAGE_BENCHMARK_WORK.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-all}"
# SALVAGE_BENCHMARK_WORK keeps the scratch build (for profiling the results executable);
# otherwise a fresh temp dir is used and removed on exit.
if [ -n "${SALVAGE_BENCHMARK_WORK:-}" ]; then
    work="$SALVAGE_BENCHMARK_WORK"; mkdir -p "$work"
else
    work="$(mktemp -d "${TMPDIR:-/tmp}/salvage-benchmark.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
fi

report="${SALVAGE_BENCHMARK_REPORT:-$work/report.jsonl}"
export SALVAGE_BENCHMARK_REPORT="$report"

run_scans() {
    local images="${SALVAGE_BENCHMARK_DIR:-$work/images}"
    mkdir -p "$images"
    for fs in exfat fat32; do
        echo "== $fs: build image (if needed), scan, recover =="
        SALVAGE_BENCHMARK=1 SALVAGE_BENCHMARK_FS="$fs" SALVAGE_BENCHMARK_DIR="$images" \
            swift test -c release --package-path "$root/SalvageCore" --filter PerformanceTests 2>&1 \
            | grep -E '^BENCHMARK|✘|error:|passed after|failed after' || true
    done
}

run_results() {
    echo "== results browser: filter/sort at ${SALVAGE_BENCHMARK_ROWS:-100000} rows =="
    local pkg="$work/results-bench"
    mkdir -p "$pkg/Sources/ResultsBench"
    cp "$root/Salvage/ViewModels/ResultsViewModel.swift" "$pkg/Sources/ResultsBench/ResultsViewModel.swift"
    cat > "$pkg/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ResultsBench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$root/SalvageCore")],
    targets: [.executableTarget(name: "ResultsBench", dependencies: [.product(name: "SalvageCore", package: "SalvageCore")],
                                swiftSettings: [.swiftLanguageMode(.v6)])]
)
EOF
    # ResultsViewModel references only ScanViewModel.State from the rest of the app.
    cat > "$pkg/Sources/ResultsBench/Stub.swift" <<'EOF'
import SalvageCore
enum ScanViewModel {
    enum State: Equatable { case idle, preparing, running, paused, resumable, completed, cancelled, failed(ScanError) }
}
EOF
    cat > "$pkg/Sources/ResultsBench/main.swift" <<'EOF'
import Foundation
import SalvageCore

let count = ProcessInfo.processInfo.environment["SALVAGE_BENCHMARK_ROWS"].flatMap(Int.init) ?? 100_000
let extensions = ["JPG", "png", "docx", "pdf", "txt", "mp3", "mov", "zip", "heic", "csv", "DS_Store"]
// Mostly ASCII names like a camera card, plus non-ASCII ones (precomposed and decomposed
// accents, CJK, emoji) and exact name+path duplicates, so the check below covers every path.
let unusual = ["Café menu", "Cafe\u{301} menu", "Résumé", "東京 写真", "naïve 🎉 party", "ÅNGSTRÖM"]
let files: [RecoveredFile] = (0..<count).map { index in
    let ext = extensions[index % extensions.count]
    var name = ext == "DS_Store" ? ".DS_Store" : (index % 3 == 0 ? "IMG_\(index).\(ext)" : "Holiday photo \(index) - edited copy.\(ext)")
    if index % 17 == 0 { name = "\(unusual[index % unusual.count]) \(index % 400).\(ext)" }
    let carved = index % 20 == 0
    let leaf = (index % 997 == 0 ? index / 2 : index) % 1000
    if index % 997 == 0 { name = "duplicate.jpg" }
    return RecoveredFile(name: carved ? "carved-\(index).\(ext)" : name,
                         path: carved ? "" : "/Folder \(leaf / 20)/Album \(leaf % 20)/\(name)",
                         sizeBytes: Int64((index &* 7919) % 5_000_000),
                         modified: carved ? nil : Date(timeIntervalSince1970: Double(1_500_000_000 + (index &* 104729) % 200_000_000)),
                         isDeleted: index % 10 == 7,
                         sourceMetadata: SourceMetadata(filesystem: carved ? .carved : .exfat, volumeOffset: index % 5 == 0 ? 0 : 1_048_576,
                                                        recordOffset: Int64(index) * 32, allocationStart: UInt64(index),
                                                        contiguous: true, rawRecord: Data(count: 96)),
                         content: index % 50 == 1 ? .unmapped : .runs([DataRun(deviceOffset: Int64(index) * 4096, length: 4096)]),
                         recoveryMethod: carved ? .carved : .metadata)
}

/// The filter/sort exactly as shipped before the batch-5 optimization, kept verbatim to time it
/// against and to check that the optimized `ResultsViewModel.apply` returns the same rows in
/// the same order.
func referenceApply(_ query: ResultsViewModel.Query, to rows: [ResultsViewModel.Row]) throws -> [ResultsViewModel.Row] {
    typealias Row = ResultsViewModel.Row
    let stride = 4096
    try Task.checkCancellation()
    var result: [Row] = []
    for (index, row) in rows.enumerated() {
        if index % stride == stride - 1 { try Task.checkCancellation() }
        if (query.showSystemFiles || !row.isSystemFile)
            && (query.category == nil || row.category == query.category)
            && (query.volume == nil || row.file.sourceMetadata.volumeOffset == query.volume)
            && (query.search.isEmpty || row.searchKey.contains(query.search)) {
            result.append(row)
        }
    }
    let ascending = query.ascending
    var comparisons = 0
    func tick() throws {
        comparisons &+= 1
        if comparisons % (stride * 4) == 0 { try Task.checkCancellation() }
    }
    func ordered<T: Comparable>(_ a: T, _ b: T, _ tieA: Row, _ tieB: Row) throws -> Bool {
        try tick()
        if a != b { return ascending ? a < b : a > b }
        return tieA.path < tieB.path
    }
    switch query.sortField {
    case .name:
        try result.sort { a, b in
            try tick()
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return ascending ? c == .orderedAscending : c == .orderedDescending }
            return a.path < b.path
        }
    case .path: try result.sort { try ordered($0.path, $1.path, $0, $1) }
    case .size: try result.sort { try ordered($0.sizeBytes, $1.sizeBytes, $0, $1) }
    case .modified: try result.sort { try ordered($0.modifiedSortKey, $1.modifiedSortKey, $0, $1) }
    }
    if result.contains(where: \.isReconstructed) {
        try Task.checkCancellation()
        result = result.filter { !$0.isReconstructed } + result.filter(\.isReconstructed)
    }
    return result
}

func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = ContinuousClock.now
    try body()
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
}
func best(_ repeats: Int = 5, _ body: () throws -> Void) rethrows -> Double {
    var result = Double.infinity
    for _ in 0..<repeats { result = min(result, try milliseconds(body)) }
    return result
}
func line(_ label: String, _ fields: String) { print("BENCHMARK {\"results\":\"\(label)\",\"rows\":\(count),\(fields)}") }

let rows = files.map(ResultsViewModel.Row.init)
line("build rows", String(format: "\"best_ms\":%.2f", best { _ = files.map(ResultsViewModel.Row.init) }))
MainActor.assumeIsolated {
    let ms = best {
        let model = ResultsViewModel(rows: rows)
        _ = model.aggregates(includingSystemFiles: false); _ = model.aggregates(includingSystemFiles: true)
    }
    line("aggregates (both settings)", String(format: "\"best_ms\":%.2f", ms))
}
typealias Q = ResultsViewModel.Query
var queries: [(String, Q)] = []
for ascending in [true, false] {
    for (field, label) in [(ResultsViewModel.SortField.name, "name"), (.path, "path"), (.size, "size"), (.modified, "modified")] {
        let direction = ascending ? "asc" : "desc"
        queries.append(("sort \(label) \(direction)", Q(category: nil, search: "", showSystemFiles: false, sortField: field, ascending: ascending)))
        queries.append(("sort \(label) \(direction) +system", Q(category: nil, search: "", showSystemFiles: true, sortField: field, ascending: ascending)))
    }
}
queries += [
    ("category pictures, name", Q(category: .pictures, search: "", showSystemFiles: false, sortField: .name, ascending: true)),
    ("volume 0, size", Q(category: nil, search: "", showSystemFiles: false, sortField: .size, ascending: true, volume: 0)),
    ("search 'photo 12', name", Q(category: nil, search: "photo 12", showSystemFiles: false, sortField: .name, ascending: true)),
    ("search 'zzz' (no match), name", Q(category: nil, search: "zzz", showSystemFiles: false, sortField: .name, ascending: true)),
    ("search 'cafe', name", Q(category: nil, search: "cafe", showSystemFiles: false, sortField: .name, ascending: true)),
    ("search 'café' (non-ASCII), name", Q(category: nil, search: "café", showSystemFiles: false, sortField: .name, ascending: true)),
    ("search 'e' (matches decomposed), path", Q(category: nil, search: "e", showSystemFiles: true, sortField: .path, ascending: true)),
    ("search '写真', size", Q(category: nil, search: "写真", showSystemFiles: false, sortField: .size, ascending: false)),
]
var mismatches = 0
for (label, query) in queries {
    var optimized: [ResultsViewModel.Row] = [], reference: [ResultsViewModel.Row] = []
    let before = try best(3) { reference = try referenceApply(query, to: rows) }
    let after = try best(3) { optimized = try ResultsViewModel.apply(query, to: rows) }
    let same = optimized.map(\.id) == reference.map(\.id)
    if !same { mismatches += 1 }
    line(label, String(format: "\"out\":%d,\"before_ms\":%.2f,\"after_ms\":%.2f,\"identical\":%@", optimized.count, before, after, same ? "true" : "false"))
}
if mismatches > 0 { print("MISMATCH: \(mismatches) queries differ from the reference"); exit(1) }
EOF
    (cd "$pkg" && swift build -c release 2>&1 | grep -E 'error|warning: unre' || true)
    "$pkg/.build/release/ResultsBench" | tee -a "$report"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "results benchmark: optimized apply differs from the reference" >&2; exit 1; }
}

case "$mode" in
    all) run_scans; run_results ;;
    scan) run_scans ;;
    results) run_results ;;
    *) echo "usage: $0 [all|scan|results]" >&2; exit 2 ;;
esac
echo "== report: $report =="
[ -f "$report" ] && cat "$report"
