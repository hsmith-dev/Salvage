import Foundation
import SalvageCore

/// Which partition a found file belongs to, for the dashboard's Partitions section and for
/// "Recover all files…" (spec-tech-recover-whole-partition).
enum PartitionKey: Hashable, Sendable {
    /// A volume (mapped or lost), identified by the start offset its files carry in
    /// `SourceMetadata.volumeOffset` and, for a volume inside an APFS container (several volumes
    /// share the container's offset), by its `SourceMetadata.volumeID`.
    case volume(Int64, volumeID: String? = nil)
    /// Reconstructed files outside every known partition, e.g. a raw whole-device sweep.
    case unpartitioned

    var offset: Int64? { if case .volume(let offset, _) = self { offset } else { nil } }
    var volumeID: String? { if case .volume(_, let id) = self { id } else { nil } }
}

/// What the dashboard knows about the scan beyond its files: volumes it had to skip, its sweep
/// extents (from its checkpoint, when there is one), and whether it ran to the end.
struct PartitionScanContext: Equatable, Sendable {
    /// A mapped volume whose metadata couldn't be read (`ScanNotice.volumeSkipped`). Its files are
    /// gone, but what the carver rebuilt from its extent still belongs to it.
    struct SkippedVolume: Equatable, Sendable {
        let offset: Int64
        let formatName: String
    }
    var skippedVolumes: [SkippedVolume] = []
    /// The scan's extents (each volume it swept), when known.
    var extents: [ScanCheckpoint.Extent] = []
    /// The scan was cancelled or failed: its results are what it found so far.
    var isIncomplete = false

    static let none = PartitionScanContext()

    init(skippedVolumes: [SkippedVolume] = [], extents: [ScanCheckpoint.Extent] = [], isIncomplete: Bool = false) {
        self.skippedVolumes = skippedVolumes; self.extents = extents; self.isIncomplete = isIncomplete
    }

    init(notices: [ScanNotice], extents: [ScanCheckpoint.Extent], isIncomplete: Bool) {
        let skipped = notices.compactMap { notice -> SkippedVolume? in
            if case .volumeSkipped(let format, let offset, _) = notice { SkippedVolume(offset: offset, formatName: format) } else { nil }
        }
        self.init(skippedVolumes: skipped, extents: extents, isIncomplete: isIncomplete)
    }
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
    /// The volume's own name inside an APFS container, e.g. "Personal"; nil otherwise.
    var volumeName: String? = nil
    /// The format in plain words ("exFAT"), for matching a sidebar partition with no offset.
    var formatName: String = "Unknown"
    /// The scan didn't run to the end, so this is what it found so far.
    var isScanIncomplete = false
    /// Recoverable files (live, deleted and reconstructed).
    var recoverableCount = 0
    var recoverableBytes: Int64 = 0
    /// Of `recoverableCount`, how many are deleted entries.
    var deletedCount = 0
    /// Of `recoverableCount`, how many were reconstructed by carving.
    var reconstructedCount = 0

    var id: PartitionKey { key }
    var offset: Int64? { key.offset }

    /// "Photos (exFAT), 63.8 GB": the row's title.
    var title: String {
        guard let sizeBytes else { return name }
        return "\(name), \(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))"
    }

    /// Files a default "Recover all files…" copies: everything but the reconstructed ones, which
    /// sit behind their checkbox (on by default only when they are all there is).
    var filesystemCount: Int { recoverableCount - reconstructedCount }

    /// "1,204 files, of which 37 deleted (+12 reconstructed)": what a default run copies, then
    /// the reconstructed files the checkbox adds. With nothing but reconstructed files, which a
    /// default run then copies: "12 reconstructed files".
    var countsText: String {
        if filesystemCount == 0, reconstructedCount > 0 {
            return "\(reconstructedCount.formatted()) reconstructed \(reconstructedCount == 1 ? "file" : "files")"
        }
        var text = ResultsViewModel.filesText(filesystemCount)
        if deletedCount > 0 { text += ", of which \(deletedCount.formatted()) deleted" }
        if reconstructedCount > 0 { text += " (+\(reconstructedCount.formatted()) reconstructed)" }
        return text
    }

    /// Whether "Recover all files…" has anything to offer (reconstructed files count: with no
    /// others, the sheet opens with them ticked).
    var canRecoverAll: Bool { recoverableCount > 0 }

    /// The row's button: an unfinished scan says the files are what it found so far.
    var recoverAllTitle: String { isScanIncomplete ? "Recover all files found so far…" : "Recover all files…" }
    var recoverAllAccessibilityLabel: String {
        isScanIncomplete ? "Recover all files found so far from \(name)" : "Recover all files from \(name)"
    }

    nonisolated static let unpartitionedName = "Unpartitioned space"
}

/// What "Recover all files…" hands the recovery sheet for one partition.
struct PartitionRecoveryPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The partition name, e.g. "Photos (exFAT)".
    let name: String
    /// Every recoverable live and deleted file of the partition, in scan order.
    let files: [RecoveredFile]
    /// The partition's recoverable reconstructed files, offered behind a checkbox (off by default,
    /// unless they are the only files).
    let reconstructed: [RecoveredFile]
    /// The scan was cancelled or failed: these are the files it found so far.
    var scanIncomplete = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.files == rhs.files && lhs.reconstructed == rhs.reconstructed
            && lhs.scanIncomplete == rhs.scanIncomplete
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

    /// "Photos (exFAT)" for a device-tree partition. A partition whose display name already is or
    /// starts with its format ("exFAT", "APFS container") keeps it alone, never "exFAT (exFAT)" or
    /// "APFS container (APFS)".
    static func displayName(of partition: DevicePartition) -> String {
        let display = partition.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = partition.formatName
        if display.isEmpty { return format }
        if display == format || display.hasPrefix(format + " ") { return display }
        return "\(display) (\(format))"
    }

    /// "Photos (exFAT)" from the device tree; an unnamed partition (whose display name is just its
    /// format) is "exFAT". Without a match: "exFAT volume at 1 MB", or "exFAT volume (whole
    /// drive)" for a filesystem that starts at the drive's first byte.
    static func name(forVolumeAt offset: Int64, formatName: String, partitions: [DevicePartition]) -> (name: String, size: Int64?) {
        if let partition = devicePartition(at: offset, in: partitions) {
            return (displayName(of: partition), partition.sizeBytes)
        }
        return (fallbackName(offset: offset, formatName: formatName), nil)
    }

    static func fallbackName(offset: Int64, formatName: String) -> String {
        offset == 0 ? "\(formatName) volume (whole drive)"
            : "\(formatName) volume at \(ByteCountFormatter.string(fromByteCount: offset, countStyle: .file))"
    }

    /// "Personal (APFS)": a volume inside an APFS container, by its own name.
    static func volumeName(_ name: String, formatName: String) -> String { "\(name) (\(formatName))" }

    static func lostPartitionName(_ partition: LostPartitionCandidate) -> String { "Lost partition — \(partition.formatName)" }

    /// The partition key a metadata file belongs to: its volume offset, plus its volume identity
    /// inside an APFS container.
    static func key(of file: RecoveredFile) -> PartitionKey {
        .volume(file.sourceMetadata.volumeOffset, volumeID: file.sourceMetadata.volumeID)
    }

    /// Assigns every row to a partition.
    ///
    /// A file found through metadata belongs to the volume its `volumeOffset` (and, in an APFS
    /// container, its `volumeID`) names. A reconstructed file's `volumeOffset` is the start of the
    /// sweep extent it was carved from, and the sweep extents are the volumes themselves, so a
    /// carve whose `volumeOffset` names a known volume lies inside it. That includes a mapped
    /// volume the scan skipped (`context.skippedVolumes`): its metadata is gone, its extent is
    /// still known. Carves can't be told apart between the volumes of one APFS container (they
    /// share its blocks), so they form the container's own group at `.volume(offset)`. Any other
    /// carve (a raw whole-device sweep) is placed by containment of its start in a known extent
    /// (device-tree partitions, lost partitions, and the scan's own extents of known volumes,
    /// innermost first), and otherwise under "Unpartitioned space".
    static func keys(for rows: [ResultsViewModel.Row], partitions: [DevicePartition],
                     lostPartitions: [LostPartitionCandidate], context: PartitionScanContext = .none) -> [PartitionKey] {
        var volumes = Set(rows.lazy.filter { !$0.isReconstructed }.map(\.file.sourceMetadata.volumeOffset))
        volumes.formUnion(lostPartitions.map(\.offset))
        volumes.formUnion(flatten(partitions).compactMap(\.offsetBytes))
        volumes.formUnion(context.skippedVolumes.map(\.offset))
        var extents = lostPartitions.map { Extent(offset: $0.offset, length: $0.sizeBytes) }
        extents += flatten(partitions).compactMap { partition in
            guard let offset = partition.offsetBytes, let size = partition.sizeBytes, size > 0 else { return nil }
            return Extent(offset: offset, length: size)
        }
        // Only extents of volumes known by other means: a scan of a drive with no partition map
        // sweeps it whole as one extent, and that is unpartitioned space, not a volume.
        extents += context.extents.filter { volumes.contains($0.offset) && $0.length > 0 }
            .map { Extent(offset: $0.offset, length: $0.length) }
        extents.sort { $0.length < $1.length }
        return rows.map { row in
            let metadata = row.file.sourceMetadata
            guard row.isReconstructed else { return key(of: row.file) }
            if volumes.contains(metadata.volumeOffset) { return .volume(metadata.volumeOffset) }
            let start = metadata.recordOffset
            if let extent = extents.first(where: { start >= $0.offset && start - $0.offset < $0.length }) {
                return .volume(extent.offset)
            }
            return .unpartitioned
        }
    }

    /// For each group the device tree couldn't name by offset (its partitions' offsets are
    /// unknown), the top-level partition it is, matched by name and format, then by size, then
    /// as the only partition of that format; nil where no match is unambiguous. Each partition
    /// matches at most one group.
    static func unplacedMatches(groups: [(key: PartitionKey, volumeName: String?, formatName: String, size: Int64?)],
                                partitions: [DevicePartition]) -> [PartitionKey: DevicePartition] {
        let unplaced = partitions.filter { $0.offsetBytes == nil }
        guard !unplaced.isEmpty else { return [:] }
        let candidates = groups.filter { group in
            guard let offset = group.key.offset else { return false }
            return devicePartition(at: offset, in: partitions) == nil
        }
        var result: [PartitionKey: DevicePartition] = [:]
        for partition in unplaced {
            let sameFormat = candidates.filter { $0.formatName == partition.formatName && result[$0.key] == nil }
            let byName = sameFormat.filter { $0.volumeName != nil && $0.volumeName == partition.displayName }
            let bySize = sameFormat.filter { partition.sizeBytes != nil && $0.size == partition.sizeBytes }
            let peers = unplaced.filter { $0.formatName == partition.formatName }
            let match: PartitionKey?
            if byName.count == 1 { match = byName[0].key }
            else if bySize.count == 1 { match = bySize[0].key }
            else if sameFormat.count == 1, peers.count == 1 { match = sameFormat[0].key }
            else { match = nil }
            if let match { result[match] = partition }
        }
        return result
    }

    /// The Partitions section: mapped volumes that produced files and every lost partition, in
    /// device order, then "Unpartitioned space" when any file landed there.
    static func summaries(rows: [ResultsViewModel.Row], keys: [PartitionKey], partitions: [DevicePartition],
                          lostPartitions: [LostPartitionCandidate], includingSystemFiles: Bool,
                          context: PartitionScanContext = .none) -> [PartitionSummary] {
        let lostByOffset = Dictionary(lostPartitions.map { ($0.offset, $0) }, uniquingKeysWith: { first, _ in first })
        let skippedByOffset = Dictionary(context.skippedVolumes.map { ($0.offset, $0.formatName) }, uniquingKeysWith: { first, _ in first })
        let extentLength = Dictionary(context.extents.map { ($0.offset, $0.length) }, uniquingKeysWith: { first, _ in first })

        // First pass: each group's identity (format, APFS volume name), in first-seen order.
        struct Identity { var formatName: String?; var volumeName: String? }
        var identities: [PartitionKey: Identity] = [:]
        var order: [PartitionKey] = []
        var formatAtOffset: [Int64: String] = [:]
        for lost in lostPartitions where identities[.volume(lost.offset)] == nil {
            identities[.volume(lost.offset)] = Identity(formatName: lost.formatName)
            order.append(.volume(lost.offset))
        }
        for (row, key) in zip(rows, keys) {
            if identities[key] == nil { identities[key] = Identity(); order.append(key) }
            guard !row.isReconstructed else { continue }
            let metadata = row.file.sourceMetadata
            let format = formatName(metadata.filesystem)
            if identities[key]?.formatName == nil { identities[key]?.formatName = format }
            if identities[key]?.volumeName == nil, let name = metadata.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty { identities[key]?.volumeName = name }
            if formatAtOffset[metadata.volumeOffset] == nil { formatAtOffset[metadata.volumeOffset] = format }
        }
        func format(of key: PartitionKey) -> String {
            if let format = identities[key]?.formatName { return format }
            guard let offset = key.offset else { return "Unknown" }
            return skippedByOffset[offset] ?? formatAtOffset[offset] ?? "Unknown"
        }
        func size(of key: PartitionKey) -> Int64? {
            guard let offset = key.offset else { return nil }
            if let lost = lostByOffset[offset] { return lost.sizeBytes }
            return devicePartition(at: offset, in: partitions)?.sizeBytes ?? extentLength[offset]
        }
        let unplaced = unplacedMatches(groups: order.map { ($0, identities[$0]?.volumeName, format(of: $0), size(of: $0)) },
                                       partitions: partitions)

        var byKey: [PartitionKey: PartitionSummary] = [:]
        for key in order {
            let identity = identities[key] ?? Identity()
            let formatName = format(of: key)
            switch key {
            case .unpartitioned:
                byKey[key] = PartitionSummary(key: key, kind: .unpartitioned, name: PartitionSummary.unpartitionedName, sizeBytes: nil,
                                              isScanIncomplete: context.isIncomplete)
            case .volume(let offset, let volumeID):
                let name: String, sizeBytes: Int64?
                if let lost = lostByOffset[offset], volumeID == nil {
                    name = lostPartitionName(lost); sizeBytes = lost.sizeBytes
                } else if let volume = identity.volumeName, volumeID != nil {
                    // A volume inside an APFS container: its own name; it shares the container's space.
                    name = volumeName(volume, formatName: formatName); sizeBytes = nil
                } else if let partition = devicePartition(at: offset, in: partitions) ?? unplaced[key] {
                    name = displayName(of: partition); sizeBytes = partition.sizeBytes ?? extentLength[offset]
                } else {
                    name = fallbackName(offset: offset, formatName: formatName); sizeBytes = extentLength[offset]
                }
                byKey[key] = PartitionSummary(key: key, kind: lostByOffset[offset] == nil ? .mapped : .lost, name: name,
                                              sizeBytes: sizeBytes, volumeName: identity.volumeName, formatName: formatName,
                                              isScanIncomplete: context.isIncomplete)
            }
        }
        for (row, key) in zip(rows, keys) {
            guard row.isRecoverable, includingSystemFiles || !row.isSystemFile else { continue }
            byKey[key]?.recoverableCount += 1
            byKey[key]?.recoverableBytes += max(0, row.sizeBytes)
            if row.file.isDeleted { byKey[key]?.deletedCount += 1 }
            if row.isReconstructed { byKey[key]?.reconstructedCount += 1 }
        }
        // Device order; volumes sharing a container in name order, its carves last.
        return byKey.values.sorted { lhs, rhs in
            switch (lhs.offset, rhs.offset) {
            case let (l?, r?):
                if l != r { return l < r }
                switch (lhs.key.volumeID, rhs.key.volumeID) {
                case (_?, nil): return true
                case (nil, _?): return false
                default: return (lhs.name, lhs.key.volumeID ?? "") < (rhs.name, rhs.key.volumeID ?? "")
                }
            case (_?, nil): return true
            case (nil, _): return false
            }
        }
    }

    /// Exactly the files "Recover all files…" copies for `key`: every recoverable file of the
    /// partition, live and deleted, honouring the system-files setting; reconstructed ones apart.
    static func plan(for summary: PartitionSummary, rows: [ResultsViewModel.Row], keys: [PartitionKey],
                     includingSystemFiles: Bool) -> PartitionRecoveryPlan {
        plan(named: summary.name, for: [summary.key], rows: rows, keys: keys, includingSystemFiles: includingSystemFiles,
             scanIncomplete: summary.isScanIncomplete)
    }

    /// The same for several groups at once (an APFS container: all its volumes and its carves).
    static func plan(named name: String, for wanted: Set<PartitionKey>, rows: [ResultsViewModel.Row], keys: [PartitionKey],
                     includingSystemFiles: Bool, scanIncomplete: Bool) -> PartitionRecoveryPlan {
        var files: [RecoveredFile] = [], reconstructed: [RecoveredFile] = []
        for (row, key) in zip(rows, keys) where wanted.contains(key) {
            guard !row.file.isUnmapped, includingSystemFiles || !row.isSystemFile else { continue }
            if row.isReconstructed { reconstructed.append(row.file) } else { files.append(row.file) }
        }
        return PartitionRecoveryPlan(name: name, files: files, reconstructed: reconstructed, scanIncomplete: scanIncomplete)
    }

    /// The groups a sidebar partition stands for. A volume inside an APFS container is its own
    /// group, matched by name (unambiguously, at the container's offset when known); otherwise it
    /// falls back to its container. A partition is every group at its offset (an APFS container:
    /// all its volumes and its carves) or, with no offset, the group matched by name, format and
    /// size (`unplacedMatches`). Empty when nothing in the scan is that partition.
    static func groups(for partition: DevicePartition, summaries: [PartitionSummary],
                       devicePartitions: [DevicePartition]) -> (name: String, summaries: [PartitionSummary]) {
        var target = partition
        if let container = devicePartitions.first(where: { top in top.children.contains { $0.id == partition.id } }) {
            let name = partition.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = summaries.filter { summary in
                summary.key.volumeID != nil && summary.volumeName == name
                    && (container.offsetBytes == nil || summary.offset == container.offsetBytes)
                    && (summary.formatName == partition.formatName || partition.formatName == "Unknown")
            }
            if matches.count == 1 { return (matches[0].name, matches) }
            target = container
        }
        var matched: [PartitionSummary]
        if let offset = target.offsetBytes {
            matched = summaries.filter { $0.offset == offset }
        } else {
            let groups = summaries.filter { $0.offset != nil }
                .map { (key: $0.key, volumeName: $0.volumeName, formatName: $0.formatName, size: $0.sizeBytes) }
            let keys = Set(unplacedMatches(groups: groups, partitions: devicePartitions).filter { $0.value.id == target.id }.keys)
            matched = summaries.filter { keys.contains($0.key) }
            // A container with no offset: all its volumes' groups, found by its volumes' names.
            if matched.isEmpty, !target.children.isEmpty {
                let names = Set(target.children.map { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines) })
                let offsets = Set(summaries.filter { $0.key.volumeID != nil && $0.volumeName.map(names.contains) == true }
                    .compactMap(\.offset))
                if offsets.count == 1 { matched = summaries.filter { $0.offset == offsets.first } }
            }
        }
        let name = matched.count == 1 ? matched[0].name : displayName(of: target)
        return (name, matched)
    }
}

extension ResultsViewModel {
    /// The Partitions section for the drive's tree, under the current system-files setting.
    /// Grouping is a full pass over the rows; it is cached by `PartitionSectionCache`.
    func partitionSummaries(devicePartitions: [DevicePartition], context: PartitionScanContext = .none,
                            cache: PartitionSectionCache) -> [PartitionSummary] {
        cache.summaries(rows: rows, partitions: devicePartitions, lostPartitions: lostPartitions,
                        includingSystemFiles: showSystemFiles, context: context)
    }

    /// The files "Recover all files…" offers for one row of the Partitions section.
    func recoverAllPlan(for summary: PartitionSummary, devicePartitions: [DevicePartition],
                        context: PartitionScanContext = .none, cache: PartitionSectionCache) -> PartitionRecoveryPlan {
        let keys = cache.keys(rows: rows, partitions: devicePartitions, lostPartitions: lostPartitions, context: context)
        return PartitionGrouping.plan(for: summary, rows: rows, keys: keys, includingSystemFiles: showSystemFiles)
    }

    /// The plan for a partition picked in the sidebar (see `PartitionGrouping.groups(for:…)`); a
    /// partition with no files in this scan yields an empty plan named after it.
    func recoverAllPlan(for partition: DevicePartition, devicePartitions: [DevicePartition],
                        context: PartitionScanContext = .none, cache: PartitionSectionCache) -> PartitionRecoveryPlan {
        let summaries = partitionSummaries(devicePartitions: devicePartitions, context: context, cache: cache)
        let (name, matched) = PartitionGrouping.groups(for: partition, summaries: summaries, devicePartitions: devicePartitions)
        guard !matched.isEmpty else {
            return PartitionRecoveryPlan(name: name, files: [], reconstructed: [], scanIncomplete: context.isIncomplete)
        }
        let keys = cache.keys(rows: rows, partitions: devicePartitions, lostPartitions: lostPartitions, context: context)
        return PartitionGrouping.plan(named: name, for: Set(matched.map(\.key)), rows: rows, keys: keys,
                                      includingSystemFiles: showSystemFiles, scanIncomplete: context.isIncomplete)
    }
}

/// Memoizes the partition grouping for one results model (its rows never change): the per-row
/// keys per device tree and scan context, and the summaries per system-files setting.
@MainActor
final class PartitionSectionCache {
    private var keyed: (partitions: [DevicePartition], context: PartitionScanContext, keys: [PartitionKey])?
    private var summaries: [Bool: [PartitionSummary]] = [:]
    /// How many times the rows were grouped (tests).
    private(set) var groupings = 0

    func keys(rows: [ResultsViewModel.Row], partitions: [DevicePartition],
              lostPartitions: [LostPartitionCandidate], context: PartitionScanContext = .none) -> [PartitionKey] {
        if let keyed, keyed.partitions == partitions, keyed.context == context { return keyed.keys }
        groupings += 1
        let keys = PartitionGrouping.keys(for: rows, partitions: partitions, lostPartitions: lostPartitions, context: context)
        keyed = (partitions, context, keys)
        summaries = [:]
        return keys
    }

    func summaries(rows: [ResultsViewModel.Row], partitions: [DevicePartition],
                   lostPartitions: [LostPartitionCandidate], includingSystemFiles: Bool,
                   context: PartitionScanContext = .none) -> [PartitionSummary] {
        let keys = keys(rows: rows, partitions: partitions, lostPartitions: lostPartitions, context: context)
        if let cached = summaries[includingSystemFiles] { return cached }
        let result = PartitionGrouping.summaries(rows: rows, keys: keys, partitions: partitions, lostPartitions: lostPartitions,
                                                 includingSystemFiles: includingSystemFiles, context: context)
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

    /// What the Partitions section needs from the scan beyond its files: the volumes it skipped,
    /// its extents (from its newest checkpoint, the only place the app sees them), and whether it
    /// was cancelled or failed.
    var partitionScanContext: PartitionScanContext {
        let incomplete: Bool
        switch state {
        case .cancelled, .failed: incomplete = true
        default: incomplete = false
        }
        return PartitionScanContext(notices: notices, extents: (latestCheckpoint ?? pendingCheckpoint)?.extents ?? [],
                                    isIncomplete: incomplete)
    }
}
