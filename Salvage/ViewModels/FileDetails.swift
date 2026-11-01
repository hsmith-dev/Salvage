import Foundation
import SalvageCore

/// Everything the details panel shows for one file (spec-tech-batch-7 §C), worked out once from
/// the `RecoveredFile` so the view only lays it out and Copy Details copies the same words.
///
/// The confidence and its sentence come from Core (`recoveryConfidence`, `confidenceExplanation`);
/// nothing here scores a file (AD-7).
struct FileDetails: Equatable, Sendable {
    struct Field: Equatable, Sendable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct Section: Equatable, Sendable, Identifiable {
        let title: String
        let fields: [Field]
        var id: String { title }
    }

    /// One run of the file's bytes, in file order.
    struct Run: Equatable, Sendable, Identifiable {
        let index: Int
        /// Where the run starts within the file.
        let fileOffset: Int64
        /// Device-absolute start; nil for a hole (reads as zeros).
        let deviceOffset: Int64?
        let length: Int64
        /// The bytes on the device are ciphertext (an unlocked FileVault volume).
        let isEncrypted: Bool
        var id: Int { index }

        var text: String {
            let size = FileDetails.bytes(length)
            guard let deviceOffset else { return "Run \(index + 1): hole, \(size), reads as zeros" }
            return "Run \(index + 1): device \(FileDetails.offset(deviceOffset)), \(size)\(isEncrypted ? ", encrypted" : "")"
        }
    }

    let name: String
    let confidence: RecoveryConfidence?
    /// The one-sentence reason for `confidence` (Core's `confidenceExplanation`).
    let explanation: String
    let sections: [Section]
    /// Where the bytes are, as one line when they aren't in device runs (resident or unmapped).
    let storage: String?
    let runs: [Run]

    /// Lines of runs Copy Details includes; a heavily fragmented file says how many it left out.
    static let maxCopiedRuns = 10_000

    init(file: RecoveredFile, device: BlockDevice? = nil, signatures: SignatureLibrary = .bundled) {
        name = file.name
        confidence = file.recoveryConfidence
        explanation = file.confidenceExplanation
        let carved = file.recoveryMethod == .carved
        let evidence = file.recoveryEvidence

        var general = [
            Field(label: "Original path", value: carved ? "Not known. Reconstructed files have no original path." : file.path),
            Field(label: "Size", value: Self.size(file.sizeBytes)),
            Field(label: "Modified", value: file.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown"),
            Field(label: "Status", value: Self.status(file)),
        ]
        if carved { general.insert(Field(label: "Listed as", value: file.path), at: 1) }

        let source = [
            Field(label: "Filesystem", value: carved ? "None. Reconstructed from raw data." : PartitionGrouping.formatName(file.sourceMetadata.filesystem)),
            Field(label: "Volume", value: Self.volume(file, device: device)),
            Field(label: "Recovery method", value: carved ? "Reconstructed from raw data by its file signature"
                                                         : "Found through the filesystem's records"),
        ] + (carved ? [] : [Field(label: "Record", value: "At device \(Self.offset(file.sourceMetadata.recordOffset))")])

        let evidenceFields = [
            Field(label: "Pieces", value: ConfidenceExplanation.fragmentsDescription(evidence, method: file.recoveryMethod)),
            Field(label: "Overwriting", value: ConfidenceExplanation.overwriteDescription(evidence)),
        ]

        var sections = [Section(title: "File", fields: general), Section(title: "Source", fields: source),
                        Section(title: "Evidence", fields: evidenceFields)]
        if carved {
            let signature = Self.signature(of: file, in: signatures)
            sections.append(Section(title: "Reconstruction", fields: [
                Field(label: "Signature", value: Self.signatureDescription(signature, file: file)),
                Field(label: "End", value: Self.endDescription(file, signature: signature)),
            ]))
        }
        self.sections = sections

        switch file.content {
        case .unmapped:
            storage = "Not located on the device."
            runs = []
        case .resident(let data):
            storage = "Stored inside the filesystem record itself (\(Self.bytes(Int64(data.count))))."
            runs = []
        case .runs(let list):
            storage = list.isEmpty ? "No data runs." : nil
            runs = Self.runs(list, encrypted: false)
        case .encryptedRuns(let list, _):
            storage = list.isEmpty ? "No data runs." : "Encrypted: the bytes on the device are ciphertext, decrypted as they're read."
            runs = Self.runs(list, encrypted: true)
        }
    }

    /// The details as plain text, in the panel's order.
    var copyText: String {
        var lines = [name, "Recovery confidence: \(confidence?.displayName ?? "Can't be recovered")", explanation]
        for section in sections {
            lines.append("")
            lines.append(section.title)
            lines += section.fields.map { "\($0.label): \($0.value)" }
        }
        lines.append("")
        lines.append("Where its bytes are")
        if let storage { lines.append(storage) }
        lines += runs.prefix(Self.maxCopiedRuns).map(\.text)
        if runs.count > Self.maxCopiedRuns {
            lines.append("… and \((runs.count - Self.maxCopiedRuns).formatted()) more runs not listed.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pieces

    static func status(_ file: RecoveredFile) -> String {
        let base = file.recoveryMethod == .carved ? "Reconstructed" : (file.isDeleted ? "Deleted" : "Live")
        return file.isPartial ? "\(base), partial — may be incomplete" : base
    }

    static func volume(_ file: RecoveredFile, device: BlockDevice?) -> String {
        let metadata = file.sourceMetadata
        let name = metadata.volumeName
            ?? device.flatMap { PartitionGrouping.devicePartition(at: metadata.volumeOffset, in: $0.partitions) }
                .map { PartitionGrouping.displayName(of: $0) }
        let at = "at device \(offset(metadata.volumeOffset))"
        guard let name, !name.isEmpty else {
            return file.recoveryMethod == .carved ? "Scanned area starting \(at)" : "Unnamed volume \(at)"
        }
        return "\(name), \(at)"
    }

    /// The signature a carve was matched by. The engine names carves "<id>-<12 hex>[-n].<ext>";
    /// when two signatures share an id, the one whose header matches the kept header bytes wins.
    static func signature(of file: RecoveredFile, in library: SignatureLibrary) -> FileSignature? {
        guard file.recoveryMethod == .carved,
              let match = file.name.wholeMatch(of: /(.+)-[0-9a-f]{12}(?:-[0-9]+)?\.([^.]+)/) else { return nil }
        let id = String(match.1), ext = String(match.2)
        let candidates = library.signatures.filter { $0.id == id && $0.extension == ext }
        let header = file.sourceMetadata.rawRecord
        return candidates.first { signature in
            signature.headers.contains { pattern in
                signature.headerOffset + pattern.count <= header.count
                    && pattern.matches(header, at: header.startIndex + signature.headerOffset)
            }
        } ?? candidates.first
    }

    static func signatureDescription(_ signature: FileSignature?, file: RecoveredFile) -> String {
        let at = "header at device \(offset(file.sourceMetadata.recordOffset))"
        guard let signature else { return "Not identified (\(at))" }
        return "\(signature.id.uppercased()) (.\(signature.extension)), \(at)"
    }

    /// How a carve's end was found. A carve that isn't partial ended by its signature's own rule;
    /// a partial one was cut short (the engine reports which kind of cut by its overwrite estimate).
    static func endDescription(_ file: RecoveredFile, signature: FileSignature?) -> String {
        if file.isPartial {
            let why: String
            switch file.overwriteConfidence {
            case 1: why = " It stopped where its data ran into another file's, or where its own structure broke."
            case 0.6: why = " It stopped at a size limit, the start of another file, the end of the scanned area, or a size too large to trust."
            default: why = ""
            }
            return "Cut short: its end couldn't be confirmed, so it may be incomplete.\(why)"
        }
        let joined = file.recoveryEvidence.fragmentCount > 1
            ? " Salvage joined \(file.recoveryEvidence.fragmentCount) pieces, checking that its data decodes across each join." : ""
        guard let signature else { return "Confirmed by its format's end rule.\(joined)" }
        if !signature.sizeFields.isEmpty { return "Size field: its header states its length.\(joined)" }
        if signature.footer != nil { return "Footer: its end marker was found.\(joined)" }
        if signature.segments != nil { return "Validated: Salvage followed its internal records to the last one.\(joined)" }
        if signature.structure != nil { return "Validated: Salvage checked its internal structure to its end.\(joined)" }
        return "Confirmed by its format's end rule.\(joined)"
    }

    private static func runs(_ list: [DataRun], encrypted: Bool) -> [Run] {
        var position: Int64 = 0
        return list.enumerated().map { index, run in
            defer { position = position.addingReportingOverflow(max(run.length, 0)).partialValue }
            return Run(index: index, fileOffset: position, deviceOffset: run.deviceOffset, length: run.length,
                       isEncrypted: encrypted && run.deviceOffset != nil)
        }
    }

    // MARK: Formatting

    static func size(_ bytes: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) (\(Self.bytes(bytes)))"
    }

    static func bytes(_ count: Int64) -> String { count == 1 ? "1 byte" : "\(count.formatted()) bytes" }

    /// "1,048,576 (0x100000)": decimal for people, hex for comparing with a hex editor.
    static func offset(_ value: Int64) -> String {
        value < 0 ? "\(value.formatted())" : "\(value.formatted()) (0x\(String(value, radix: 16)))"
    }
}
