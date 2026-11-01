import Foundation

/// `structure: "gzip"`: finds the exact end of a gzip file by decoding it.
///
/// The member header (RFC 1952: FLG reserved bits clear, FEXTRA, FNAME, FCOMMENT, and FHCRC when
/// present, which is verified) is parsed, then the DEFLATE stream (RFC 1951) is decoded block by
/// block to its final block, keeping only the 32 KiB back-reference window, a running CRC-32 and
/// the output length. The 8-byte trailer must then match both: only then is the end validated.
/// Members that follow directly are walked too (a multi-member gzip), except at a sector boundary,
/// where a new member is as likely to be the next file.
///
/// Apple's Compression framework is not used: AD-1 keeps SalvageCore on Foundation only, and its
/// streaming API doesn't report how many input bytes a raw DEFLATE stream consumed.
///
/// The decoder is resumable at every step (a block header, one symbol, part of a stored block):
/// a step that runs out of window is retried with more bytes, so nothing but the decoder state is
/// kept between chunks. Invalid data ends the carve as inconsistent where it was found; a
/// trailer mismatch ends it as inconsistent after the trailer; a stream that decodes to more than
/// `maxOutput` bytes is abandoned (open-ended, partial) to cap the CPU spent on one candidate.
final class GzipWalker: CarveWalker, @unchecked Sendable {
    static let maxOutput: Int64 = 2 << 30
    /// Longest FNAME / FCOMMENT accepted.
    static let maxHeaderString: Int64 = 64 * 1024

    private enum State {
        case header
        case block
        case stored(Int)
        case codes
        case trailer
        /// After a verified trailer: another member may follow.
        case member
    }

    let start: Int64
    let sectorSize: Int64
    private var memberStart: Int64
    /// End of the last member whose trailer verified.
    private var verifiedEnd: Int64?
    /// Absolute bit position of the next unread bit.
    private var bit: Int64 = 0
    private var state = State.header
    private var lastBlock = false
    private var literals = Huffman.fixedLiterals
    private var distances = Huffman.fixedDistances
    private var window = [UInt8](repeating: 0, count: 32768)
    private var windowPosition = 0
    private var produced: Int64 = 0
    private var crc: UInt32 = 0xFFFF_FFFF

    init(start: Int64, sectorSize: Int) {
        self.start = start
        self.sectorSize = Int64(max(sectorSize, 1))
        memberStart = start
    }

    private var byte: Int64 { bit >> 3 }
    var retainFrom: Int64 {
        switch state {
        case .header: memberStart
        case .member: verifiedEnd ?? memberStart
        default: byte
        }
    }
    var cover: Int64? { retainFrom }
    var sizeDerived: Bool { false }

    func absorbs(at position: Int64, weak: Bool, embedded: Bool, trustedMax: Int64) -> Bool {
        position < retainFrom && weak
    }

    func advance(through limit: Int64, _ w: Window) -> WalkOutcome {
        while true {
            guard retainFrom <= limit else { return .paused }
            switch state {
            case .header:
                switch parseHeader(w) {
                case .ok(let dataStart):
                    let (position, overflow) = dataStart.multipliedReportingOverflow(by: 8)
                    guard !overflow else { return .end(start, .inconsistent) }
                    bit = position
                    resetMember()
                    state = .block
                case .needBytes:
                    // At the end of the extent, a later member that can't be read isn't part of it.
                    if w.final, let verifiedEnd { return .end(verifiedEnd, .validated) }
                    return .needBytes
                case .invalid:
                    // Not a gzip header after all; a later one just ends the previous member.
                    if let verifiedEnd { return .end(verifiedEnd, .validated) }
                    return .end(start, .inconsistent)
                }

            case .block:
                var reader = BitReader(w, bit: bit)
                guard let isFinal = reader.bits(1), let type = reader.bits(2) else { return .needBytes }
                switch type {
                case 0:
                    reader.alignToByte()
                    guard let length = reader.bits(16), let complement = reader.bits(16) else { return .needBytes }
                    guard length ^ complement == 0xFFFF else { return invalid() }
                    state = .stored(Int(length))
                case 1:
                    literals = Huffman.fixedLiterals
                    distances = Huffman.fixedDistances
                    state = .codes
                case 2:
                    switch Self.dynamicTables(&reader) {
                    case .needBytes: return .needBytes
                    case .invalid: return invalid()
                    case .tables(let lit, let dist):
                        literals = lit
                        distances = dist
                        state = .codes
                    }
                default:
                    return invalid()
                }
                lastBlock = isFinal == 1
                bit = reader.absolute

            case .stored(let remaining):
                if remaining == 0 {
                    state = lastBlock ? .trailer : .block
                    continue
                }
                // One byte per step, so no step starts past `limit`.
                let available = min(Int64(remaining), w.end - byte, limit - byte + 1)
                guard available > 0 else { return .needBytes }
                var position = w.index(byte)
                for _ in 0..<available {
                    output(w.buffer[position])
                    position += 1
                }
                bit += available * 8
                state = .stored(remaining - Int(available))
                if produced > Self.maxOutput { return .openEnded(.limit) }

            case .codes:
                var reader = BitReader(w, bit: bit)
                let limitBit = (limit - w.start + 1) * 8
                while true {
                    guard Int64(reader.position) < limitBit else {
                        bit = reader.absolute
                        return .paused
                    }
                    var step = reader
                    let symbol = literals.decode(&step)
                    if symbol == Huffman.needBytes { bit = reader.absolute; return .needBytes }
                    guard symbol >= 0 else { bit = reader.absolute; return invalid() }
                    if symbol < 256 {
                        output(UInt8(symbol))
                        reader = step
                        continue
                    }
                    if symbol == 256 {
                        reader = step
                        state = lastBlock ? .trailer : .block
                        break
                    }
                    let lengthCode = symbol - 257
                    guard lengthCode < 29 else { bit = reader.absolute; return invalid() }
                    guard let lengthExtra = step.bits(Self.lengthExtra[lengthCode]) else { bit = reader.absolute; return .needBytes }
                    let length = Self.lengthBase[lengthCode] + Int(lengthExtra)
                    let distanceCode = distances.decode(&step)
                    if distanceCode == Huffman.needBytes { bit = reader.absolute; return .needBytes }
                    guard distanceCode >= 0, distanceCode < 30 else { bit = reader.absolute; return invalid() }
                    guard let distanceExtra = step.bits(Self.distanceExtra[distanceCode]) else { bit = reader.absolute; return .needBytes }
                    let distance = Self.distanceBase[distanceCode] + Int(distanceExtra)
                    guard Int64(distance) <= produced else { bit = reader.absolute; return invalid() }
                    reader = step
                    var from = (windowPosition - distance) & 0x7FFF
                    for _ in 0..<length {
                        output(window[from])
                        from = (from + 1) & 0x7FFF
                    }
                    if produced > Self.maxOutput { bit = reader.absolute; return .openEnded(.limit) }
                }
                bit = reader.absolute

            case .trailer:
                let (aligned, overflow) = bit.addingReportingOverflow(7)
                guard !overflow else { return invalid() }
                let trailer = aligned >> 3
                guard trailer <= w.end - 8 else { return .needBytes }
                guard let storedCRC = w.readUInt(at: trailer, width: 4, endian: .little),
                      let storedSize = w.readUInt(at: trailer + 4, width: 4, endian: .little) else { return .needBytes }
                let end = trailer + 8
                guard UInt32(storedCRC) == ~crc, storedSize == UInt64(UInt32(truncatingIfNeeded: produced)) else {
                    return .end(end, .inconsistent)
                }
                verifiedEnd = end
                bit = end * 8
                state = .member

            case .member:
                guard let end = verifiedEnd else { return invalid() }
                if end % sectorSize == 0 { return .end(end, .validated) }
                guard end <= w.end - 3 else { return w.final ? .end(end, .validated) : .needBytes }
                guard w.matches([0x1F, 0x8B, 0x08], at: end) else { return .end(end, .validated) }
                memberStart = end
                state = .header
            }
        }
    }

    /// Bad data where a DEFLATE structure must be: the carve ends at the last byte read.
    private func invalid() -> WalkOutcome {
        let (rounded, overflow) = bit.addingReportingOverflow(7)
        return .end(overflow ? byte : max(rounded >> 3, start), .inconsistent)
    }

    private func resetMember() {
        lastBlock = false
        windowPosition = 0
        produced = 0
        crc = 0xFFFF_FFFF
    }

    @inline(__always) private func output(_ value: UInt8) {
        window[windowPosition] = value
        windowPosition = (windowPosition + 1) & 0x7FFF
        crc = CRC32.table[Int((crc ^ UInt32(value)) & 0xFF)] ^ (crc >> 8)
        produced += 1
    }

    private enum HeaderResult { case ok(Int64), needBytes, invalid }

    private func parseHeader(_ w: Window) -> HeaderResult {
        var position = memberStart
        func available(_ count: Int64) -> Bool { position <= w.end - count }
        guard available(10) else { return .needBytes }
        guard w.matches([0x1F, 0x8B, 0x08], at: position), let flags = w.byte(at: position + 3) else { return .invalid }
        guard flags & 0xE0 == 0 else { return .invalid }
        position += 10
        if flags & 0x04 != 0 {
            guard available(2) else { return .needBytes }
            guard let length = w.readUInt(at: position, width: 2, endian: .little) else { return .needBytes }
            position += 2
            guard available(Int64(length)) else { return .needBytes }
            position += Int64(length)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            let stringStart = position
            while true {
                guard let value = w.byte(at: position) else { return .needBytes }
                position += 1
                if value == 0 { break }
                guard position - stringStart < Self.maxHeaderString else { return .invalid }
            }
        }
        if flags & 0x02 != 0 {
            guard available(2), let stored = w.readUInt(at: position, width: 2, endian: .little) else { return .needBytes }
            var check = CRC32()
            for offset in w.index(memberStart)..<w.index(position) { check.update(w.buffer[offset]) }
            guard UInt16(truncatingIfNeeded: check.value) == UInt16(stored) else { return .invalid }
            position += 2
        }
        return .ok(position)
    }

    // MARK: DEFLATE tables

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                       4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private enum Tables { case tables(Huffman, Huffman), needBytes, invalid }

    /// Reads a dynamic block's code-length code and literal/length and distance tables (RFC 1951
    /// 3.2.7). Incomplete codes are refused except a single one-bit code, as zlib does.
    private static func dynamicTables(_ reader: inout BitReader) -> Tables {
        guard let hlit = reader.bits(5), let hdist = reader.bits(5), let hclen = reader.bits(4) else { return .needBytes }
        let literalCount = Int(hlit) + 257, distanceCount = Int(hdist) + 1, lengthCodes = Int(hclen) + 4
        guard literalCount <= 286, distanceCount <= 30 else { return .invalid }
        var codeLengths = [UInt8](repeating: 0, count: 19)
        for index in 0..<lengthCodes {
            guard let value = reader.bits(3) else { return .needBytes }
            codeLengths[codeLengthOrder[index]] = UInt8(value)
        }
        guard let lengthCode = Huffman(lengths: codeLengths), lengthCode.left == 0 else { return .invalid }
        var lengths = [UInt8](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < lengths.count {
            let symbol = lengthCode.decode(&reader)
            if symbol == Huffman.needBytes { return .needBytes }
            guard symbol >= 0 else { return .invalid }
            if symbol < 16 {
                lengths[index] = UInt8(symbol)
                index += 1
                continue
            }
            var value: UInt8 = 0, repeatCount: Int
            switch symbol {
            case 16:
                guard index > 0 else { return .invalid }
                value = lengths[index - 1]
                guard let extra = reader.bits(2) else { return .needBytes }
                repeatCount = 3 + Int(extra)
            case 17:
                guard let extra = reader.bits(3) else { return .needBytes }
                repeatCount = 3 + Int(extra)
            default:
                guard let extra = reader.bits(7) else { return .needBytes }
                repeatCount = 11 + Int(extra)
            }
            guard index + repeatCount <= lengths.count else { return .invalid }
            for _ in 0..<repeatCount {
                lengths[index] = value
                index += 1
            }
        }
        guard lengths[256] != 0 else { return .invalid }
        guard let literals = Huffman(lengths: Array(lengths[0..<literalCount])),
              literals.left == 0 || literals.isSingleOneBitCode,
              let distances = Huffman(lengths: Array(lengths[literalCount...])),
              distances.left == 0 || distances.isSingleOneBitCode else { return .invalid }
        return .tables(literals, distances)
    }
}

/// LSB-first bit reader over a window, positioned in bits from the window's start.
struct BitReader {
    let buffer: UnsafeRawBufferPointer
    let windowStart: Int64
    let endBits: Int
    var position: Int

    init(_ w: Window, bit: Int64) {
        buffer = w.buffer
        windowStart = w.start
        endBits = buffer.count * 8
        position = Int(bit - w.start * 8)
    }

    var absolute: Int64 { windowStart * 8 + Int64(position) }
    var remaining: Int { endBits - position }

    mutating func alignToByte() { position = (position + 7) & ~7 }

    /// The next `count` (0...16) bits, LSB first; nil when the window ends first.
    mutating func bits(_ count: Int) -> UInt32? {
        guard count > 0 else { return 0 }
        guard position >= 0, remaining >= count else { return nil }
        var value: UInt32 = 0, got = 0, at = position
        while got < count {
            let current = UInt32(buffer[at >> 3]) >> UInt32(at & 7)
            let take = min(8 - (at & 7), count - got)
            value |= (current & ((1 << UInt32(take)) - 1)) << UInt32(got)
            got += take
            at += take
        }
        position = at
        return value
    }

    func peek(_ count: Int) -> UInt32? {
        var copy = self
        return copy.bits(count)
    }
}

/// A canonical Huffman code (RFC 1951 3.2.2) with a 9-bit lookup table for short codes.
struct Huffman: Sendable {
    static let needBytes = -2
    static let fastBits = 9

    private var count = [Int](repeating: 0, count: 16)
    private var symbols: [Int] = []
    /// `symbol << 4 | length` for codes up to `fastBits` long, indexed by the next bits; 0 if none.
    private var fast = [UInt16](repeating: 0, count: 1 << 9)
    /// Codes left unassigned: negative is over-subscribed (refused), 0 complete, positive incomplete.
    private(set) var left = 0
    /// Symbols with a code.
    private(set) var used = 0
    /// The only incomplete code DEFLATE decoders accept: a single one-bit code.
    var isSingleOneBitCode: Bool { used == 1 && count[1] == 1 }

    /// nil when the lengths are over-subscribed.
    init?(lengths: [UInt8]) {
        for length in lengths { count[Int(length)] += 1 }
        used = lengths.count - count[0]
        var left = 1
        for length in 1..<16 {
            left <<= 1
            left -= count[length]
            if left < 0 { return nil }
        }
        self.left = left
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1..<15 { offsets[length + 1] = offsets[length] + count[length] }
        symbols = [Int](repeating: 0, count: used)
        for (symbol, length) in lengths.enumerated() where length != 0 {
            symbols[offsets[Int(length)]] = symbol
            offsets[Int(length)] += 1
        }
        // Canonical codes, bit-reversed into the LSB-first lookup table.
        var code = 0
        var next = [Int](repeating: 0, count: 16)
        for length in 1..<16 {
            code = (code + (length == 1 ? 0 : count[length - 1])) << 1
            next[length] = code
        }
        for (symbol, length) in lengths.enumerated() where length != 0 {
            let bits = Int(length)
            let assigned = next[bits]
            next[bits] += 1
            guard bits <= Self.fastBits else { continue }
            var reversed = 0
            for index in 0..<bits where assigned & (1 << index) != 0 { reversed |= 1 << (bits - 1 - index) }
            for slot in stride(from: reversed, to: 1 << Self.fastBits, by: 1 << bits) {
                fast[slot] = UInt16(symbol << 4 | bits)
            }
        }
    }

    /// The next symbol; -1 for a code not in the table, `needBytes` when the window ends first.
    func decode(_ reader: inout BitReader) -> Int {
        if let peeked = reader.peek(Self.fastBits) {
            let entry = Int(fast[Int(peeked)])
            if entry != 0 {
                reader.position += entry & 15
                return entry >> 4
            }
        }
        var code = 0, first = 0, index = 0
        for length in 1..<16 {
            guard let bit = reader.bits(1) else { return Self.needBytes }
            code |= Int(bit)
            let countHere = count[length]
            if code - countHere < first { return symbols[index + (code - first)] }
            index += countHere
            first += countHere
            first <<= 1
            code <<= 1
        }
        return -1
    }

    static let fixedLiterals: Huffman = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for index in 144..<256 { lengths[index] = 9 }
        for index in 256..<280 { lengths[index] = 7 }
        return Huffman(lengths: lengths)!
    }()

    static let fixedDistances: Huffman = Huffman(lengths: [UInt8](repeating: 5, count: 30))!
}

/// CRC-32 (IEEE 802.3, reflected), as gzip uses it.
struct CRC32 {
    static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF
    var value: UInt32 { ~state }

    mutating func update(_ byte: UInt8) {
        state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
    }
}
