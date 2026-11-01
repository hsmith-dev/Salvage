import Foundation
import SalvageCore

/// One JSON object per line (JSON Lines), keys sorted so output is stable.
enum JSONLine {
    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// ISO 8601 in UTC, e.g. "2026-10-31T14:02:11Z".
    static func date(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return date.formatted(.iso8601)
    }

    static func file(_ file: RecoveredFile) -> [String: Any] {
        let confidence: Any = file.recoveryConfidence.map { $0.displayName.lowercased() } ?? NSNull()
        var encrypted = false
        if case .encryptedRuns = file.content { encrypted = true }
        return [
            "type": "file",
            "name": file.name,
            "path": file.path,
            "size": file.sizeBytes,
            "modified": date(file.modified),
            "deleted": file.isDeleted,
            "method": file.recoveryMethod == .carved ? "carved" : "metadata",
            "partial": file.isPartial,
            "recoverable": !file.isUnmapped,
            "confidence": confidence,
            "category": file.category.rawValue,
            "filesystem": file.sourceMetadata.filesystem.rawValue,
            "volumeOffset": file.sourceMetadata.volumeOffset,
            "volumeName": file.sourceMetadata.volumeName ?? NSNull(),
            "encrypted": encrypted,
        ]
    }

    static func notice(_ notice: ScanNotice) -> [String: Any] {
        var object: [String: Any] = ["type": "notice", "kind": kind(of: notice), "message": notice.text]
        switch notice {
        case .volumeSkipped(let format, let offset, let reason):
            object["format"] = format; object["offset"] = offset; object["reason"] = reason
        case .carvingLimitReached(let count): object["count"] = count
        case .unreadableAreasSkipped(let count): object["count"] = count
        case .damagedItemsSkipped(let count, let examples): object["count"] = count; object["examples"] = examples
        case .lostPartitionSearchLimited(let searched, let device): object["searchedBytes"] = searched; object["deviceBytes"] = device
        case .partitionTableIgnored(let reason): object["reason"] = reason
        case .signaturesSkipped(let files): object["files"] = files
        case .resumedCarvingPartial: break
        }
        return object
    }

    static func kind(of notice: ScanNotice) -> String {
        switch notice {
        case .partitionTableIgnored: "partitionTableIgnored"
        case .lostPartitionSearchLimited: "lostPartitionSearchLimited"
        case .unreadableAreasSkipped: "unreadableAreasSkipped"
        case .carvingLimitReached: "carvingLimitReached"
        case .signaturesSkipped: "signaturesSkipped"
        case .resumedCarvingPartial: "resumedCarvingPartial"
        case .volumeSkipped: "volumeSkipped"
        case .damagedItemsSkipped: "damagedItemsSkipped"
        }
    }

    static func lostPartition(_ partition: LostPartitionCandidate) -> [String: Any] {
        ["type": "lostPartition", "offset": partition.offset, "size": partition.sizeBytes, "format": partition.formatName]
    }
}
