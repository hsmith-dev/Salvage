import Foundation
import SalvageCore

/// Which partition a found file belongs to, for the dashboard's Partitions section and for
/// "Recover all files…" (spec-tech-recover-whole-partition).
enum PartitionKey: Hashable, Sendable {
    /// A volume (mapped or lost), identified by the start offset its files carry in
    /// `SourceMetadata.volumeOffset`.
    case volume(Int64)
    /// Reconstructed files outside every known partition, e.g. a raw whole-device sweep.
    case unpartitioned
}

/// One row of the dashboard's Partitions section: a mapped volume that produced files, a lost
/// partition, or the unpartitioned space. Counts are recoverable files only, under one
/// "Show system files" setting.
struct PartitionSummary: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case mapped, lost, unpartitioned }

    let key: PartitionKey
    let kind: Kind
    /// "Photos (exFAT)": used for the recovery folder and the summary sentence.
    let name: String
    /// The partition's size when known.
    let sizeBytes: Int64?
    /// Recoverable files (live, deleted and reconstructed).
    var recoverableCount = 0
    var recoverableBytes: Int64 = 0
    /// Of `recoverableCount`, how many are deleted entries.
    var deletedCount = 0
    /// Of `recoverableCount`, how many were reconstructed by carving.
    var reconstructedCount = 0

    var id: PartitionKey { key }
    var offset: Int64? { if case .volume(let offset) = key { offset } else { nil } }

    /// "Photos (exFAT), 63.8 GB": the row's title.
    var title: String {
        guard let sizeBytes else { return name }
        return "\(name), \(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))"
    }

    /// "1,204 files, of which 37 deleted and 12 reconstructed".
    var countsText: String {
        var text = ResultsViewModel.filesText(recoverableCount)
        var parts: [String] = []
        if deletedCount > 0 { parts.append("\(deletedCount.formatted()) deleted") }
        if reconstructedCount > 0 { parts.append("\(reconstructedCount.formatted()) reconstructed") }
        if !parts.isEmpty { text += ", of which " + parts.joined(separator: " and ") }
        return text
    }

    /// Whether "Recover all files…" has anything to offer (reconstructed files count, behind
    /// their checkbox).
    var canRecoverAll: Bool { recoverableCount > 0 }

    nonisolated static let unpartitionedName = "Unpartitioned space"
}

/// What "Recover all files…" hands the recovery sheet for one partition.
struct PartitionRecoveryPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The partition name, e.g. "Photos (exFAT)".
    let name: String
    /// Every recoverable live and deleted file of the partition, in scan order.
    let files: [RecoveredFile]
    /// The partition's recoverable reconstructed files, offered behind a checkbox (off by default).
    let reconstructed: [RecoveredFile]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.files == rhs.files && lhs.reconstructed == rhs.reconstructed
    }
}

/// Grouping and naming, pure so every rule is unit-tested without a scan.
enum PartitionGrouping {
    /// A known extent a reconstructed file can be contained in.
    private struct Extent { let offset: Int64; let length: Int64 }

    /// Every partition of a drive's tree, containers' volumes included, flattened.
    static func flatten(_ partitions: [DevicePartition]) -> [DevicePartition] {
        partitions.flatMap { [$0] + flatten($0.children) }
    }

    /// The device-tree partition starting at `offset`, matched by equality; nil when none does.
    static func devicePartition(at offset: Int64, in partitions: [DevicePartition]) -> DevicePartition? {
        flatten(partitions).first { $0.offsetBytes == offset }
    }

    /// Format names for the fallback when no device-tree partition matches.
    static func formatName(_ filesystem: SourceMetadata.Filesystem) -> String {
        switch filesystem {
        case .fat32: "FAT32"
        case .exfat: "exFAT"
        case .ntfs: "NTFS"
        case .ext: "Linux (EXT)"
        case .apfs: "APFS"
        case .hfsPlus: "HFS+"
        case .carved: "Unknown"
        }
    }

    /// "Photos (exFAT)" from the device tree; an unnamed partition (whose display name is just its
    /// format) is "exFAT". Without a match: "exFAT volume at 1 MB".
    static func name(forVolumeAt offset: Int64, formatName: String, partitions: [DevicePartition]) -> (name: String, size: Int64?) {
        if let partition = devicePartition(at: offset, in: partitions) {
            let display = partition.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let format = partition.formatName
            let name = display.isEmpty || display == format ? format : "\(display) (\(format))"
            return (name, partition.sizeBytes)
        }
        return ("\(formatName) volume at \(ByteCountFormatter.string(fromByteCount: offset, countStyle: .file))", nil)
    }

    static func lostPartitionName(_ partition: LostPartitionCandidate) -> String { "Lost partition — \(partition.formatName)" }

    /// Assigns every row to a partition.
    ///
    /// A file found through metadata belongs to the volume its `volumeOffset` names. A
    /// reconstructed file's `volumeOffset` is the start of the sweep extent it was carved from,
    /// and the sweep extents are the volumes themselves, so a carve whose `volumeOffset` names a
    /// known volume lies inside it. Any other carve (a raw whole-device sweep) is placed by
    /// containment of its start in a known extent (device-tree partitions and lost partitions,
    /// innermost first), and otherwise under "Unpartitioned space".
    static func keys(for rows: [ResultsViewModel.Row], partitions: [DevicePartition],
                     lostPartitions: [LostPartitionCandidate]) -> [PartitionKey] {
        var volumes = Set(rows.lazy.filter { !$0.isReconstructed }.map(\.file.sourceMetadata.volumeOffset))
        volumes.formUnion(lostPartitions.map(\.offset))
        volumes.formUnion(flatten(partitions).compactMap(\.offsetBytes))
        var extents = lostPartitions.map { Extent(offset: $0.offset, length: $0.sizeBytes) }
        extents += flatten(partitions).compactMap { partition in
            guard let offset = partition.offsetBytes, let size = partition.sizeBytes, size > 0 else { return nil }
            return Extent(offset: offset, length: size)
        }
        extents.sort { $0.length < $1.length }
        return rows.map { row in
            let metadata = row.file.sourceMetadata
            guard row.isReconstructed else { return .volume(metadata.volumeOffset) }
            if volumes.contains(metadata.volumeOffset) { return .volume(metadata.volumeOffset) }
            let start = metadata.recordOffset
            if let extent = extents.first(where: { start >= $0.offset && start - $0.offset < $0.length }) {
                return .volume(extent.offset)
            }
            return .unpartitioned
        }
    }

    /// The Partitions section: mapped volumes that produced files and every lost partition, in
    /// device order, then "Unpartitioned space" when any file landed there.
    static func summaries(rows: [ResultsViewModel.Row], keys: [PartitionKey], partitions: [DevicePartition],
                          lostPartitions: [LostPartitionCandidate], includingSystemFiles: Bool) -> [PartitionSummary] {
        let lostByOffset = Dictionary(lostPartitions.map { ($0.offset, $0) }, uniquingKeysWith: { first, _ in first })
        var byKey: [PartitionKey: PartitionSummary] = [:]
        for lost in lostPartitions where byKey[.volume(lost.offset)] == nil {
            byKey[.volume(lost.offset)] = PartitionSummary(key: .volume(lost.offset), kind: .lost,
                                                           name: lostPartitionName(lost), sizeBytes: lost.sizeBytes)
        }
        for (row, key) in zip(rows, keys) {
            if byKey[key] == nil {
                switch key {
                case .unpartitioned:
                    byKey[key] = PartitionSummary(key: key, kind: .unpartitioned, name: PartitionSummary.unpartitionedName, sizeBytes: nil)
                case .volume(let offset):
                    let format = row.isReconstructed ? "Unknown" : formatName(row.file.sourceMetadata.filesystem)
                    let named = name(forVolumeAt: offset, formatName: format, partitions: partitions)
                    byKey[key] = PartitionSummary(key: key, kind: lostByOffset[offset] == nil ? .mapped : .lost,
                                                  name: named.name, sizeBytes: named.size)
                }
            }
            guard row.isRecoverable, includingSystemFiles || !row.isSystemFile else { continue }
            byKey[key]?.recoverableCount += 1
            byKey[key]?.recoverableBytes += max(0, row.sizeBytes)
            if row.file.isDeleted { byKey[key]?.deletedCount += 1 }
            if row.isReconstructed { byKey[key]?.reconstructedCount += 1 }
        }
        return byKey.values.sorted { lhs, rhs in
            switch (lhs.offset, rhs.offset) {
            case let (l?, r?): l < r
            case (_?, nil): true
            case (nil, _): false
            }
        }
    }

    /// Exactly the files "Recover all files…" copies for `key`: every recoverable file of the
    /// partition, live and deleted, honouring the system-files setting; reconstructed ones apart.
    static func plan(for summary: PartitionSummary, rows: [ResultsViewModel.Row], keys: [PartitionKey],
                     includingSystemFiles: Bool) -> PartitionRecoveryPlan {
        var files: [RecoveredFile] = [], reconstructed: [RecoveredFile] = []
        for (row, key) in zip(rows, keys) where key == summary.key {
            guard !row.file.isUnmapped, includingSystemFiles || !row.isSystemFile else { continue }
            if row.isReconstructed { reconstructed.append(row.file) } else { files.append(row.file) }
        }
        return PartitionRecoveryPlan(name: summary.name, files: files, reconstructed: reconstructed)
    }
}

extension ResultsViewModel {
    /// The Partitions section for the drive's tree, under the current system-files setting.
    /// Grouping is a full pass over the rows; it is cached by `PartitionSectionCache`.
    func partitionSummaries(devicePartitions: [DevicePartition], cache: PartitionSectionCache) -> [PartitionSummary] {
        cache.summaries(rows: rows, partitions: devicePartitions, lostPartitions: lostPartitions,
                        includingSystemFiles: showSystemFiles)
    }

    /// The files "Recover all files…" offers for one row of the Partitions section.
    func recoverAllPlan(for summary: PartitionSummary, devicePartitions: [DevicePartition],
                        cache: PartitionSectionCache) -> PartitionRecoveryPlan {
        let keys = cache.keys(rows: rows, partitions: devicePartitions, lostPartitions: lostPartitions)
        return PartitionGrouping.plan(for: summary, rows: rows, keys: keys, includingSystemFiles: showSystemFiles)
    }

    /// The plan for a partition picked in the sidebar: matched by its start offset; a partition
    /// with no files in this scan yields an empty plan named after it.
    func recoverAllPlan(for partition: DevicePartition, devicePartitions: [DevicePartition],
                        cache: PartitionSectionCache) -> PartitionRecoveryPlan {
        let summaries = partitionSummaries(devicePartitions: devicePartitions, cache: cache)
        if let offset = partition.offsetBytes, let summary = summaries.first(where: { $0.key == .volume(offset) }) {
            return recoverAllPlan(for: summary, devicePartitions: devicePartitions, cache: cache)
        }
        let format = partition.formatName
        let name = partition.displayName == format ? format : "\(partition.displayName) (\(format))"
        return PartitionRecoveryPlan(name: name, files: [], reconstructed: [])
    }
}

/// Memoizes the partition grouping for one results model (its rows never change): the per-row
/// keys per device tree, and the summaries per system-files setting.
@MainActor
final class PartitionSectionCache {
    private var keyed: (partitions: [DevicePartition], keys: [PartitionKey])?
    private var summaries: [Bool: [PartitionSummary]] = [:]
    /// How many times the rows were grouped (tests).
    private(set) var groupings = 0

    func keys(rows: [ResultsViewModel.Row], partitions: [DevicePartition],
              lostPartitions: [LostPartitionCandidate]) -> [PartitionKey] {
        if let keyed, keyed.partitions == partitions { return keyed.keys }
        groupings += 1
        let keys = PartitionGrouping.keys(for: rows, partitions: partitions, lostPartitions: lostPartitions)
        keyed = (partitions, keys)
        summaries = [:]
        return keys
    }

    func summaries(rows: [ResultsViewModel.Row], partitions: [DevicePartition],
                   lostPartitions: [LostPartitionCandidate], includingSystemFiles: Bool) -> [PartitionSummary] {
        let keys = keys(rows: rows, partitions: partitions, lostPartitions: lostPartitions)
        if let cached = summaries[includingSystemFiles] { return cached }
        let result = PartitionGrouping.summaries(rows: rows, keys: keys, partitions: partitions,
                                                 lostPartitions: lostPartitions, includingSystemFiles: includingSystemFiles)
        summaries[includingSystemFiles] = result
        return result
    }
}

/// A "Recover all files…" request from the sidebar's partition context menu.
struct PartitionRecoveryRequest: Identifiable, Equatable {
    let id = UUID()
    let partition: DevicePartition
}

extension ScanViewModel {
    /// The drive whose scan has finished with results still open for recovery, if any: the
    /// sidebar offers "Recover all files…" on that drive's partitions only.
    var deviceWithFinishedResults: BlockDevice? {
        guard source != nil,
              ResultsViewModel.showsResults(state: state, isActive: isActive, fileCount: files.count) else { return nil }
        return device
    }
}
