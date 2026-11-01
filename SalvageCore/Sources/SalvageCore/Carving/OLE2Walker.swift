import Foundation

/// `structure: "ole2"`: finds the exact end of an OLE2 compound file (Office 97-2003 .doc/.xls/
/// .ppt, .msg) from its sector allocation table.
///
/// The header gives the sector size, the FAT sector count, the first 109 FAT sector numbers (the
/// DIFAT; more in chained DIFAT sectors), the first directory sector and the mini-FAT chain. As
/// the sweep passes them, the walker reads every DIFAT and FAT sector and the first directory
/// sector (sectors may sit anywhere in the file, often at its end). Once the whole FAT is known
/// it is validated before anything is trusted:
/// - every entry is free, end-of-chain, a FAT/DIFAT marker or a sector number inside the FAT;
/// - the sectors the DIFAT names are marked as FAT (DIFAT) sectors, and no other sector is;
/// - every chain is acyclic, no sector has two predecessors, and no pointer reaches a free or
///   marker sector;
/// - the directory and mini-FAT chains start at chain heads, with the lengths the header gives;
/// - every stream in the first directory sector stored in the FAT (and the root's mini stream)
///   starts a chain exactly `ceil(size / sectorSize)` sectors long.
/// The file then ends after the highest sector any FAT entry allocates.
///
/// A broken header or any failed check makes the carve inconsistent (partial); a FAT sector the
/// sweep already passed (a DIFAT sector naming an earlier one) can't be read in a streaming pass,
/// so the carve falls back to running open-ended (partial).
final class OLE2Walker: CarveWalker, @unchecked Sendable {
    static let headerBytes = 512
    private static let free: UInt32 = 0xFFFF_FFFF, endOfChain: UInt32 = 0xFFFF_FFFE
    private static let fatMarker: UInt32 = 0xFFFF_FFFD, difatMarker: UInt32 = 0xFFFF_FFFC
    private static let maxRegular: UInt32 = 0xFFFF_FFFA

    private enum Read { case fat(Int), difat(Int), directory }

    let start: Int64
    let maxBytes: Int64
    private var parsed = false
    private var shift = 9
    private var sectorSize = 512
    private var perSector = 128
    private var fatSectors: [UInt32] = []
    private var difatSectors: [UInt32] = []
    private var expectedDIFAT = 0
    private var fat: [UInt32] = []
    private var directoryStart: UInt32 = 0
    private var directorySectors = 0
    private var miniFATStart: UInt32 = 0
    private var miniFATSectors = 0
    private var majorVersion = 3
    /// Chains the directory says must exist: start sector and sector count.
    private var expectedChains: [(start: UInt32, sectors: Int)] = []
    /// Sector reads still to do, in device order.
    private var pending: [(offset: Int64, read: Read)] = []
    private var scheduled: Set<UInt32> = []

    init(start: Int64, maxBytes: Int64) {
        self.start = start
        self.maxBytes = maxBytes
    }

    var retainFrom: Int64 { parsed ? (pending.first?.offset ?? start) : start }
    var cover: Int64? { nil }
    var sizeDerived: Bool { true }

    func absorbs(at position: Int64, weak: Bool, embedded: Bool, trustedMax: Int64) -> Bool {
        // The end isn't known until the whole FAT is read.
        weak
    }

    func advance(through limit: Int64, _ w: Window) -> WalkOutcome {
        if !parsed {
            guard start <= w.end - Int64(Self.headerBytes) else { return .needBytes }
            guard parseHeader(w) else { return .openEnded(.inconsistent) }
            parsed = true
        }
        while let (offset, read) = pending.first {
            guard offset <= limit else { return .paused }
            guard offset >= w.start else { return .openEnded(.limit) }
            guard offset <= w.end - Int64(sectorSize) else { return .needBytes }
            pending.removeFirst()
            let base = w.index(offset)
            func entry(_ index: Int) -> UInt32 {
                let at = base + index * 4
                return UInt32(w.buffer[at]) | UInt32(w.buffer[at + 1]) << 8 | UInt32(w.buffer[at + 2]) << 16 | UInt32(w.buffer[at + 3]) << 24
            }
            switch read {
            case .fat(let ordinal):
                for index in 0..<perSector { fat[ordinal * perSector + index] = entry(index) }
            case .difat(let ordinal):
                let first = 109 + ordinal * (perSector - 1)
                for index in 0..<perSector - 1 {
                    let value = entry(index), slot = first + index
                    if slot < fatSectors.count {
                        guard schedule(value, .fat(slot), w) else { return failure(w, value) }
                        fatSectors[slot] = value
                    } else if value != Self.free {
                        return .openEnded(.inconsistent)
                    }
                }
                let following = entry(perSector - 1)
                if ordinal + 1 < expectedDIFAT {
                    guard schedule(following, .difat(ordinal + 1), w) else { return failure(w, following) }
                    difatSectors.append(following)
                } else if following != Self.endOfChain, following != Self.free {
                    return .openEnded(.inconsistent)
                }
            case .directory:
                guard readDirectory(w, base: base) else { return .openEnded(.inconsistent) }
            }
        }
        guard difatSectors.count == expectedDIFAT else { return .openEnded(.inconsistent) }
        return validate()
    }

    /// A sector named after the sweep passed it can't be read: give up rather than guess.
    private func failure(_ w: Window, _ sector: UInt32) -> WalkOutcome {
        guard sector < UInt32(fat.count), !scheduled.contains(sector) else { return .openEnded(.inconsistent) }
        return .openEnded(.limit)
    }

    /// Device offset of a sector (sector -1 is the header); nil on overflow.
    private func offset(of sector: UInt32) -> Int64? {
        let (position, overflow) = start.addingReportingOverflow((Int64(sector) + 1) << shift)
        return overflow ? nil : position
    }

    /// Queues a sector read; false when the sector is out of range, already used, or behind the
    /// window.
    private func schedule(_ sector: UInt32, _ read: Read, _ w: Window) -> Bool {
        guard sector < UInt32(fat.count), !scheduled.contains(sector) else { return false }
        guard let at = offset(of: sector), at >= w.start else { return false }
        scheduled.insert(sector)
        let index = pending.firstIndex { $0.offset > at } ?? pending.count
        pending.insert((at, read), at: index)
        return true
    }

    private func parseHeader(_ w: Window) -> Bool {
        func u16(_ at: Int) -> Int? { w.readUInt(at: start + Int64(at), width: 2, endian: .little).map(Int.init) }
        func u32(_ at: Int) -> UInt32? { w.readUInt(at: start + Int64(at), width: 4, endian: .little).map { UInt32($0) } }
        guard let major = u16(0x1A), let order = u16(0x1C), let sectorShift = u16(0x1E), let miniShift = u16(0x20),
              let dirCount = u32(0x28), let fatCount = u32(0x2C), let dirStart = u32(0x30), let cutoff = u32(0x38),
              let miniStart = u32(0x3C), let miniCount = u32(0x40), let difatStart = u32(0x44), let difatCount = u32(0x48)
        else { return false }
        guard order == 0xFFFE, miniShift == 6, cutoff == 4096,
              (major == 3 && sectorShift == 9) || (major == 4 && sectorShift == 12) else { return false }
        majorVersion = major
        shift = sectorShift
        sectorSize = 1 << shift
        perSector = sectorSize / 4
        // Bound the FAT by the largest file the signature allows.
        let maxSectors = maxBytes >> shift
        let maxFAT = maxSectors / Int64(perSector) + 1
        guard fatCount >= 1, Int64(fatCount) <= maxFAT else { return false }
        let fatSectorCount = Int(fatCount)
        let extra = max(0, fatSectorCount - 109)
        let neededDIFAT = (extra + perSector - 2) / (perSector - 1)
        guard Int(difatCount) == neededDIFAT else { return false }
        guard major == 4 || dirCount == 0, Int64(dirCount) <= maxSectors, Int64(miniCount) <= maxSectors else { return false }
        fat = [UInt32](repeating: Self.free, count: fatSectorCount * perSector)
        fatSectors = [UInt32](repeating: Self.free, count: fatSectorCount)
        expectedDIFAT = neededDIFAT
        directoryStart = dirStart
        directorySectors = Int(dirCount)
        miniFATStart = miniStart
        miniFATSectors = Int(miniCount)
        for slot in 0..<109 {
            guard let value = u32(0x4C + slot * 4) else { return false }
            if slot < fatSectorCount {
                guard schedule(value, .fat(slot), w) else { return false }
                fatSectors[slot] = value
            } else if value != Self.free {
                return false
            }
        }
        if neededDIFAT > 0 {
            guard schedule(difatStart, .difat(0), w) else { return false }
            difatSectors.append(difatStart)
        } else if difatStart != Self.endOfChain, difatStart != Self.free {
            return false
        }
        guard schedule(dirStart, .directory, w) else { return false }
        return true
    }

    /// Checks the first directory sector and records the chains its streams need.
    private func readDirectory(_ w: Window, base: Int) -> Bool {
        let entries = sectorSize / 128
        for entry in 0..<entries {
            let at = base + entry * 128
            func u16(_ offset: Int) -> Int { Int(w.buffer[at + offset]) | Int(w.buffer[at + offset + 1]) << 8 }
            func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
            let nameLength = u16(0x40), type = w.buffer[at + 0x42]
            guard [0, 1, 2, 5].contains(type), (type == 5) == (entry == 0) else { return false }
            guard type != 0 else { continue }
            guard nameLength >= 2, nameLength <= 64, nameLength % 2 == 0, w.buffer[at + 0x43] <= 1 else { return false }
            guard type == 2 || type == 5 else { continue }
            let start = u32(0x74)
            // Version 3 files may carry garbage in the size's high half.
            let size = majorVersion == 3 ? UInt64(u32(0x78)) : UInt64(u32(0x78)) | UInt64(u32(0x7C)) << 32
            guard size <= UInt64(maxBytes) else { return false }
            guard type == 5 || size >= 4096 else { continue }
            if size == 0 { continue }
            let sectors = (size + UInt64(sectorSize) - 1) >> UInt64(shift)
            expectedChains.append((start, Int(sectors)))
        }
        return true
    }

    private func validate() -> WalkOutcome {
        let count = fat.count
        var hasPredecessor = [Bool](repeating: false, count: count)
        var highest = -1
        var fatMarks = 0, difatMarks = 0
        for index in 0..<count {
            let value = fat[index]
            switch value {
            case Self.free: continue
            case Self.endOfChain: break
            case Self.fatMarker: fatMarks += 1
            case Self.difatMarker: difatMarks += 1
            case 0...Self.maxRegular:
                let target = Int(value)
                guard target < count, target != index, !hasPredecessor[target] else { return .openEnded(.inconsistent) }
                hasPredecessor[target] = true
            default: return .openEnded(.inconsistent)
            }
            highest = index
        }
        // Sectors the DIFAT names carry the FAT (DIFAT) marker; some writers (Cocoa's .doc writer)
        // mark them as a one-sector chain instead, which is accepted only for a sector nothing
        // points to. No sector the DIFAT doesn't name may carry a marker.
        func marked(_ sectors: [UInt32], _ marker: UInt32) -> Int? {
            var count = 0
            for sector in sectors {
                let value = fat[Int(sector)]
                if value == marker { count += 1; continue }
                guard value == Self.endOfChain, !hasPredecessor[Int(sector)] else { return nil }
            }
            return count
        }
        guard highest >= 0, marked(fatSectors, Self.fatMarker) == fatMarks,
              marked(difatSectors, Self.difatMarker) == difatMarks else { return .openEnded(.inconsistent) }
        func isChainSector(_ value: UInt32) -> Bool { value <= Self.maxRegular || value == Self.endOfChain }
        // Walk every chain from its head; a chain sector never reached sits on a cycle.
        var chainLength: [UInt32: Int] = [:]
        var visited = [Bool](repeating: false, count: count)
        for head in 0..<count where isChainSector(fat[head]) && !hasPredecessor[head] {
            var sector = head, length = 0
            while true {
                guard length < count else { return .openEnded(.inconsistent) }
                visited[sector] = true
                length += 1
                let value = fat[sector]
                if value == Self.endOfChain { break }
                guard isChainSector(fat[Int(value)]) else { return .openEnded(.inconsistent) }
                sector = Int(value)
            }
            chainLength[UInt32(head)] = length
        }
        for index in 0..<count where isChainSector(fat[index]) && !visited[index] { return .openEnded(.inconsistent) }
        func chain(_ start: UInt32, sectors: Int?) -> Bool {
            guard let length = chainLength[start] else { return false }
            return sectors.map { $0 == length } ?? true
        }
        guard chain(directoryStart, sectors: directorySectors > 0 ? directorySectors : nil) else { return .openEnded(.inconsistent) }
        if miniFATSectors > 0 {
            guard chain(miniFATStart, sectors: miniFATSectors) else { return .openEnded(.inconsistent) }
        } else if miniFATStart != Self.endOfChain, miniFATStart != Self.free {
            return .openEnded(.inconsistent)
        }
        for expected in expectedChains where !chain(expected.start, sectors: expected.sectors) { return .openEnded(.inconsistent) }
        let (sectors, overflow) = Int64(highest + 2).multipliedReportingOverflow(by: Int64(sectorSize))
        guard !overflow else { return .openEnded(.inconsistent) }
        let (end, endOverflow) = start.addingReportingOverflow(sectors)
        guard !endOverflow else { return .openEnded(.inconsistent) }
        return .end(end, .validated)
    }
}
