import Foundation

// A baseline (SOF0) / extended sequential Huffman (SOF1) JPEG entropy decoder (ITU T.81), used to
// validate carved JPEGs and the joins of reassembled ones. It parses DQT/DHT/SOF/DRI/SOS and decodes
// every MCU's DC and AC coefficients, checking the Huffman codes, the coefficient positions, the DC
// range the quantizer allows, restart marker placement and numbering, and that the scan ends with
// EOI after exactly the frame's MCU count. It produces no pixels. Progressive, lossless,
// hierarchical and arithmetic-coded JPEGs, multi-scan baseline files and DNL-sized frames are
// reported as unsupported, never as invalid.

/// A canonical Huffman table from a DHT segment (T.81 Annex C, F.2.2.3).
final class JPEGHuffmanTable: @unchecked Sendable {
    static let lookupBits = 9
    /// Largest code of each length (index 1...16); -1 when that length has no codes.
    let maxCode: [Int32]
    /// Added to a code of that length to index `values`.
    let valueOffset: [Int32]
    let values: [UInt8]
    /// For every `lookupBits`-bit prefix: `length << 8 | symbol` of the code it starts with, or 0
    /// when the code is longer.
    let lookup: [UInt16]

    /// Nil when the counts are inconsistent (too many codes for a length, or a code of all one
    /// bits, which T.81 reserves and libjpeg rejects too).
    /// Immutable copies of `lookup`, of `maxCode` and `valueOffset` interleaved (`2 * length`,
    /// `2 * length + 1`), and of `values` (padded to 256), for the decode loop. Never written after
    /// `init`, which is why the class is `@unchecked Sendable`.
    private let fastLookup: UnsafeMutablePointer<UInt16>
    private let codeLimits: UnsafeMutablePointer<Int32>
    private let fastValues: UnsafeMutablePointer<UInt8>

    init?(counts: [UInt8], values: [UInt8]) {
        guard counts.count == 16 else { return nil }
        let total = counts.reduce(0) { $0 + Int($1) }
        guard total > 0, total <= 256, values.count == total else { return nil }
        var maxCode = [Int32](repeating: -1, count: 18)
        var valueOffset = [Int32](repeating: 0, count: 18)
        var lookup = [UInt16](repeating: 0, count: 1 << Self.lookupBits)
        var code: Int32 = 0, index: Int32 = 0
        for length in 1...16 {
            valueOffset[length] = index - code
            let count = Int(counts[length - 1])
            for _ in 0..<count {
                guard code < (Int32(1) << length) - 1 else { return nil }
                if length <= Self.lookupBits {
                    let shift = Self.lookupBits - length
                    let first = Int(code) << shift
                    let entry = UInt16(length) << 8 | UInt16(values[Int(index)])
                    for slot in first..<first + (1 << shift) { lookup[slot] = entry }
                }
                code += 1; index += 1
            }
            if count > 0 { maxCode[length] = code - 1 }
            code <<= 1
        }
        self.maxCode = maxCode; self.valueOffset = valueOffset; self.values = values; self.lookup = lookup
        fastLookup = .allocate(capacity: lookup.count)
        fastLookup.initialize(from: lookup, count: lookup.count)
        codeLimits = .allocate(capacity: 36)
        for length in 0..<18 { codeLimits[2 * length] = maxCode[length]; codeLimits[2 * length + 1] = valueOffset[length] }
        fastValues = .allocate(capacity: 256)
        fastValues.initialize(repeating: 0, count: 256)
        fastValues.update(from: values, count: values.count)
    }

    deinit {
        fastLookup.deallocate(); codeLimits.deallocate(); fastValues.deallocate()
    }

    /// `length << 8 | symbol` of the code at the top of `bits` (`count` valid bits), 0 when more
    /// bits are needed, -1 when no code matches.
    @inline(__always)
    func decode(_ bits: UInt64, _ count: Int) -> Int {
        let lookupBits = Self.lookupBits
        if count >= lookupBits {
            let entry = fastLookup[Int(truncatingIfNeeded: (bits >> UInt64(count - lookupBits)) & UInt64((1 << lookupBits) - 1))]
            if entry != 0 { return Int(entry) }
        }
        var code: Int32 = 0
        for length in 1...16 {
            guard length <= count else { return 0 }
            code = code << 1 | Int32(truncatingIfNeeded: (bits >> UInt64(count - length)) & 1)
            if code <= codeLimits[2 * length] { return length << 8 | Int(fastValues[Int(code + codeLimits[2 * length + 1])]) }
        }
        return -1
    }
}

/// What one scan looks like to the entropy decoder: its tables, MCU structure and size.
final class JPEGScanLayout: Sendable {
    let blocksPerMCU: Int
    let totalMCUs: Int
    let restartInterval: Int
    /// Scan component index of each block of an MCU, in coding order.
    let blockComponent: [Int]
    let dcTables: [JPEGHuffmanTable]
    let acTables: [JPEGHuffmanTable]
    /// Largest quantized DC magnitude each component can hold (from the DC quantizer).
    let dcLimit: [Int32]
    let maxDCCategory: Int
    let maxACCategory: Int
    init(blockComponent: [Int], totalMCUs: Int, restartInterval: Int, dcTables: [JPEGHuffmanTable],
         acTables: [JPEGHuffmanTable], dcLimit: [Int32], precision: Int) {
        self.blockComponent = blockComponent; self.blocksPerMCU = blockComponent.count
        self.totalMCUs = totalMCUs; self.restartInterval = restartInterval
        self.dcTables = dcTables; self.acTables = acTables; self.dcLimit = dcLimit
        maxDCCategory = precision + 3; maxACCategory = precision + 2
    }

}

/// Collects the header segments before start-of-scan and builds the scan layout.
struct JPEGHeaderParser: Sendable {
    struct Component: Sendable { let id: UInt8; let h: Int; let v: Int; let quantTable: Int }
    struct Frame: Sendable {
        let extended: Bool
        let precision: Int
        let width: Int
        let height: Int
        let components: [Component]
    }

    /// Why the decoder can't judge this file; nil while it can.
    private(set) var unsupported: String?
    /// DC (first) entry of each quantization table.
    private var quantDC: [Int?] = [nil, nil, nil, nil]
    private var dcTables: [JPEGHuffmanTable?] = [nil, nil, nil, nil]
    private var acTables: [JPEGHuffmanTable?] = [nil, nil, nil, nil]
    private(set) var frame: Frame?
    private var restartInterval = 0

    /// Markers whose payload the decoder needs before the scan.
    static func needsPayload(_ marker: UInt8) -> Bool {
        marker == 0xC0 || marker == 0xC1 || marker == 0xC4 || marker == 0xDB || marker == 0xDD || marker == 0xDA
    }

    mutating func markUnsupported(_ reason: String) {
        if unsupported == nil { unsupported = reason }
    }

    /// Takes one header segment (the bytes after its two length bytes).
    mutating func segment(marker: UInt8, payload: UnsafeRawBufferPointer) {
        guard unsupported == nil else { return }
        switch marker {
        case 0xC0, 0xC1: parseFrame(payload, extended: marker == 0xC1)
        case 0xC4: parseHuffman(payload)
        case 0xDB: parseQuantization(payload)
        case 0xDD:
            guard payload.count == 2 else { return markUnsupported("bad DRI segment") }
            restartInterval = Int(payload[0]) << 8 | Int(payload[1])
        case 0xC2, 0xC3, 0xC5...0xC7, 0xC8...0xCB, 0xCD...0xCF: markUnsupported("not a baseline or extended Huffman JPEG")
        case 0xCC: markUnsupported("arithmetic coding")
        case 0xDC, 0xDE, 0xDF: markUnsupported("DNL or hierarchical marker")
        default: break // APPn, COM and others carry nothing the decoder needs.
        }
    }

    private mutating func parseFrame(_ payload: UnsafeRawBufferPointer, extended: Bool) {
        guard frame == nil else { return markUnsupported("more than one frame header") }
        guard payload.count >= 6 else { return markUnsupported("short SOF segment") }
        let precision = Int(payload[0])
        let height = Int(payload[1]) << 8 | Int(payload[2])
        let width = Int(payload[3]) << 8 | Int(payload[4])
        let count = Int(payload[5])
        guard precision == 8 || (extended && precision == 12) else { return markUnsupported("sample precision \(precision)") }
        guard height > 0 else { return markUnsupported("height defined by DNL") }
        guard width > 0, (1...4).contains(count), payload.count == 6 + 3 * count else { return markUnsupported("bad SOF segment") }
        var components: [Component] = []
        for index in 0..<count {
            let base = 6 + 3 * index
            let id = payload[base], sampling = payload[base + 1], table = Int(payload[base + 2])
            let h = Int(sampling >> 4), v = Int(sampling & 0xF)
            guard (1...4).contains(h), (1...4).contains(v), table <= 3, !components.contains(where: { $0.id == id }) else {
                return markUnsupported("bad SOF component")
            }
            components.append(Component(id: id, h: h, v: v, quantTable: table))
        }
        frame = Frame(extended: extended, precision: precision, width: width, height: height, components: components)
    }

    private mutating func parseHuffman(_ payload: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < payload.count {
            guard offset + 17 <= payload.count else { return markUnsupported("short DHT segment") }
            let tableClass = payload[offset] >> 4, slot = Int(payload[offset] & 0xF)
            guard tableClass <= 1, slot <= 3 else { return markUnsupported("bad DHT table id") }
            let counts = Array(payload[offset + 1..<offset + 17])
            let total = counts.reduce(0) { $0 + Int($1) }
            guard offset + 17 + total <= payload.count else { return markUnsupported("short DHT segment") }
            let values = Array(payload[offset + 17..<offset + 17 + total])
            guard let table = JPEGHuffmanTable(counts: counts, values: values) else { return markUnsupported("bad Huffman table") }
            if tableClass == 0 { dcTables[slot] = table } else { acTables[slot] = table }
            offset += 17 + total
        }
    }

    private mutating func parseQuantization(_ payload: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < payload.count {
            let wide = payload[offset] >> 4, slot = Int(payload[offset] & 0xF)
            guard wide <= 1, slot <= 3 else { return markUnsupported("bad DQT table id") }
            let size = wide == 1 ? 128 : 64
            guard offset + 1 + size <= payload.count else { return markUnsupported("short DQT segment") }
            let dc = wide == 1 ? Int(payload[offset + 1]) << 8 | Int(payload[offset + 2]) : Int(payload[offset + 1])
            guard dc > 0 else { return markUnsupported("zero quantizer") }
            quantDC[slot] = dc
            offset += 1 + size
        }
    }

    /// The layout of the scan a start-of-scan segment opens, or nil (with `unsupported` set) when
    /// the decoder can't judge it.
    mutating func layout(startOfScan payload: UnsafeRawBufferPointer) -> JPEGScanLayout? {
        guard unsupported == nil else { return nil }
        guard let frame else { markUnsupported("scan before frame header"); return nil }
        guard payload.count >= 1 else { markUnsupported("short SOS segment"); return nil }
        let count = Int(payload[0])
        guard payload.count == 4 + 2 * count else { markUnsupported("bad SOS segment"); return nil }
        // One scan must carry every component (the usual single interleaved baseline scan).
        guard count == frame.components.count else { markUnsupported("multi-scan sequential JPEG"); return nil }
        let spectral = (payload[1 + 2 * count], payload[2 + 2 * count], payload[3 + 2 * count])
        guard spectral.0 == 0, spectral.1 == 63, spectral.2 == 0 else { markUnsupported("not a sequential scan"); return nil }
        let maxSlot: UInt8 = frame.extended ? 3 : 1
        var dc: [JPEGHuffmanTable] = [], ac: [JPEGHuffmanTable] = [], limits: [Int32] = []
        for index in 0..<count {
            let id = payload[1 + 2 * index], tables = payload[2 + 2 * index]
            guard frame.components[index].id == id else { markUnsupported("scan components out of frame order"); return nil }
            let dcSlot = tables >> 4, acSlot = tables & 0xF
            guard dcSlot <= maxSlot, acSlot <= maxSlot, let dcTable = dcTables[Int(dcSlot)], let acTable = acTables[Int(acSlot)] else {
                markUnsupported("missing Huffman table"); return nil
            }
            guard let quant = quantDC[frame.components[index].quantTable] else { markUnsupported("missing quantization table"); return nil }
            dc.append(dcTable); ac.append(acTable)
            // The DC coefficient of an 8-bit block lies in -1024...1016 (12-bit: 16 times that);
            // the slack covers encoder rounding.
            let range = frame.precision == 8 ? 1024 : 16384
            limits.append(Int32(range / quant + 2))
        }
        let maxH = frame.components.map(\.h).max() ?? 1, maxV = frame.components.map(\.v).max() ?? 1
        func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }
        let blocks: [Int], total: Int
        if count == 1 {
            // A non-interleaved scan: one block per MCU, over the component's own dimensions.
            let component = frame.components[0]
            let width = ceilDiv(frame.width * component.h, maxH), height = ceilDiv(frame.height * component.v, maxV)
            blocks = [0]
            total = ceilDiv(width, 8) * ceilDiv(height, 8)
        } else {
            guard frame.components.reduce(0, { $0 + $1.h * $1.v }) <= 10 else { markUnsupported("too many blocks per MCU"); return nil }
            blocks = frame.components.enumerated().flatMap { index, component in Array(repeating: index, count: component.h * component.v) }
            total = ceilDiv(frame.width, 8 * maxH) * ceilDiv(frame.height, 8 * maxV)
        }
        return JPEGScanLayout(blockComponent: blocks, totalMCUs: total, restartInterval: restartInterval,
                              dcTables: dc, acTables: ac, dcLimit: limits, precision: frame.precision)
    }
}

/// The streaming entropy decoder of one scan. It is a value: copying it snapshots the decode at a
/// byte boundary, and the copy can continue on other bytes (how a reassembly join is tried).
///
/// Bytes are fed in stream order (`feed`); every complete Huffman symbol is decoded as soon as its
/// bits have arrived, so the state after feeding a given byte range doesn't depend on how the
/// range was split.
struct JPEGScanDecoder: Sendable {
    enum Status: Sendable, Equatable {
        case decoding
        /// A restart interval ended; the next thing must be the expected RST marker.
        case awaitingRestart
        /// Every MCU of the frame is decoded; the next thing must be EOI.
        case awaitingEnd
        /// EOI followed the last MCU.
        case complete
        case invalid
    }

    let layout: JPEGScanLayout
    let scanStart: Int64
    private(set) var status = Status.decoding
    /// Offset of the next byte to feed.
    private(set) var position: Int64
    private(set) var mcusDecoded = 0
    private(set) var restartMarkers = 0
    /// False once a restart marker came out of place or out of sequence.
    private(set) var restartSequenceOK = true
    /// Offset of the last accepted restart marker (the scan start before any).
    private(set) var lastRestart: Int64
    private var bits: UInt64 = 0
    private var bitCount = 0
    private var pendingFF = false
    private var block = 0
    private var coefficient = 0
    private var predictors = SIMD4<Int32>(repeating: 0)
    private var nextRestart: UInt8 = 0
    /// Bits read but not yet decoded when the decode failed.
    private var unusedAtFailure = 0

    init(layout: JPEGScanLayout, start: Int64) {
        self.layout = layout; scanStart = start; position = start; lastRestart = start
    }

    var isLive: Bool { status == .decoding || status == .awaitingRestart || status == .awaitingEnd }

    /// Bytes before this offset decoded consistently. After a failure this is an estimate (the
    /// failing symbol starts at or after it); otherwise it is `position`.
    var validUpTo: Int64 {
        status == .invalid ? max(scanStart, position - Int64((unusedAtFailure + 7) / 8)) : position
    }

    /// The same decode state, continuing with the bytes at `offset` (a reassembly join).
    func resumed(at offset: Int64) -> JPEGScanDecoder {
        var copy = self
        copy.position = offset
        return copy
    }

    /// Feeds `position..<end`, which `buffer` (starting at stream offset `bufferStart`) must hold.
    /// Stops early when the scan completes or fails. Returns the number of bytes consumed.
    @discardableResult
    mutating func feed(_ buffer: UnsafeRawBufferPointer, at bufferStart: Int64, upTo end: Int64) -> Int64 {
        guard isLive, end > position else { return 0 }
        let begin = position
        guard position >= bufferStart, end - bufferStart <= Int64(buffer.count) else { fail(); return 0 }
        var index = Int(position - bufferStart)
        let stop = Int(end - bufferStart)
        while index < stop {
            let byte = buffer[index]
            index += 1
            if pendingFF {
                if byte == 0x00 {
                    pendingFF = false
                    push(0xFF)
                } else if byte != 0xFF {
                    pendingFF = false
                    position = bufferStart + Int64(index)
                    marker(byte)
                } // FF FF: fill bytes before a marker.
            } else if byte == 0xFF {
                pendingFF = true
            } else {
                push(byte)
            }
            if !isLive { break }
        }
        position = bufferStart + Int64(index)
        if status == .decoding || status == .awaitingRestart || status == .awaitingEnd { drain() }
        return position - begin
    }

    private mutating func fail() {
        if status != .invalid { unusedAtFailure = bitCount }
        status = .invalid
    }

    @inline(__always)
    private mutating func push(_ byte: UInt8) {
        // Entropy-coded data where a marker must come.
        guard status == .decoding else { return fail() }
        bits = bits << 8 | UInt64(byte)
        bitCount += 8
        if bitCount >= 40 { drain() }
    }

    @inline(__always)
    private func peekSymbol(_ table: JPEGHuffmanTable) -> Int { table.decode(bits, bitCount) }

    @inline(__always)
    private mutating func take(_ count: Int) -> Int32 {
        bitCount -= count
        return Int32(truncatingIfNeeded: (bits >> UInt64(bitCount)) & ((1 << UInt64(count)) - 1))
    }

    /// Decodes every symbol whose bits have arrived.
    private mutating func drain() {
        while status == .decoding {
            let component = layout.blockComponent[block]
            if coefficient == 0 {
                let symbol = peekSymbol(layout.dcTables[component])
                if symbol == 0 { return }
                guard symbol > 0 else { return fail() }
                let length = symbol >> 8, size = symbol & 0xFF
                guard size <= layout.maxDCCategory else { return fail() }
                guard bitCount >= length + size else { return }
                bitCount -= length
                var difference: Int32 = 0
                if size > 0 {
                    difference = take(size)
                    if difference < Int32(1) << (size - 1) { difference -= (Int32(1) << size) - 1 }
                }
                let value = predictors[component] &+ difference
                guard abs(value) <= layout.dcLimit[component] else { return fail() }
                predictors[component] = value
                coefficient = 1
            } else {
                // The AC coefficients of one block, with the state in locals.
                let table = layout.acTables[component], maxSize = layout.maxACCategory, bits = self.bits
                var count = bitCount, k = coefficient
                var blockEnded = false, failed = false
                while true {
                    let symbol = table.decode(bits, count)
                    guard symbol > 0 else { failed = symbol < 0; break }
                    let length = symbol >> 8, run = (symbol >> 4) & 0xF, size = symbol & 0xF
                    if size == 0 {
                        if run == 15 {
                            // ZRL: sixteen zeros, and a coefficient must still fit after them.
                            guard k + 16 <= 63 else { failed = true; break }
                            count -= length
                            k += 16
                            continue
                        }
                        guard run == 0 else { failed = true; break }
                        count -= length // EOB
                        blockEnded = true
                        break
                    }
                    guard size <= maxSize else { failed = true; break }
                    guard count >= length + size else { break }
                    guard k + run <= 63 else { failed = true; break }
                    count -= length + size
                    k += run + 1
                    if k == 64 { blockEnded = true; break }
                }
                bitCount = count
                coefficient = k
                if failed { return fail() }
                guard blockEnded else { return }
                endBlock()
            }
        }
        // After an interval or the last MCU only the padding of the current byte may follow.
        if status != .decoding, bitCount >= 8 { fail() }
    }

    @inline(__always)
    private mutating func endBlock() {
        coefficient = 0
        block += 1
        guard block == layout.blocksPerMCU else { return }
        block = 0
        mcusDecoded += 1
        if mcusDecoded == layout.totalMCUs {
            status = .awaitingEnd
        } else if layout.restartInterval > 0, mcusDecoded % layout.restartInterval == 0 {
            status = .awaitingRestart
        }
    }

    /// The bits left before a marker are byte padding: fewer than eight, all ones.
    private var paddingIsValid: Bool {
        guard bitCount < 8 else { return false }
        let mask: UInt64 = (1 << UInt64(bitCount)) - 1
        return bits & mask == mask
    }

    private mutating func marker(_ code: UInt8) {
        drain()
        guard isLive else { return }
        switch code {
        case 0xD0...0xD7:
            guard status == .awaitingRestart, code == 0xD0 | nextRestart, paddingIsValid else {
                restartSequenceOK = false
                return fail()
            }
            bits = 0; bitCount = 0
            predictors = SIMD4(repeating: 0)
            nextRestart = (nextRestart + 1) & 7
            restartMarkers += 1
            lastRestart = position - 2
            status = .decoding
        case 0xD9:
            guard status == .awaitingEnd, paddingIsValid else { return fail() }
            status = .complete
        default:
            fail()
        }
    }
}

/// The verdict on one whole JPEG file.
struct JPEGDecodeResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// Every MCU decoded and EOI followed.
        case complete
        /// The entropy data is inconsistent at about `validUpTo`.
        case invalid
        /// The data ran out before the scan ended.
        case truncated
        /// The decoder can't judge this file (progressive, arithmetic, missing tables, ...).
        case unsupported(String)
    }
    let outcome: Outcome
    let mcusDecoded: Int
    let totalMCUs: Int
    /// Bytes before this offset (from the start of the file) decoded consistently.
    let validUpTo: Int
    let restartSequenceOK: Bool
    let restartMarkers: Int
}

enum JPEGBaselineDecoder {
    /// Decodes a whole JPEG file held in memory.
    static func decode(_ data: Data) -> JPEGDecodeResult {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> JPEGDecodeResult in
            func unsupported(_ reason: String, _ offset: Int = 0) -> JPEGDecodeResult {
                JPEGDecodeResult(outcome: .unsupported(reason), mcusDecoded: 0, totalMCUs: 0, validUpTo: offset,
                                 restartSequenceOK: true, restartMarkers: 0)
            }
            guard buffer.count >= 4, buffer[0] == 0xFF, buffer[1] == 0xD8 else { return unsupported("no SOI marker") }
            var parser = JPEGHeaderParser()
            var offset = 2
            while true {
                guard offset + 1 < buffer.count, buffer[offset] == 0xFF else { return unsupported("broken header", offset) }
                var markerAt = offset + 1
                while markerAt < buffer.count, buffer[markerAt] == 0xFF { markerAt += 1 }
                guard markerAt + 2 < buffer.count else { return unsupported("truncated header", offset) }
                let marker = buffer[markerAt]
                guard marker != 0xD9 else { return unsupported("no scan", offset) }
                guard marker != 0x00, marker != 0x01, marker != 0xD8, !(0xD0...0xD7).contains(marker) else {
                    return unsupported("unexpected marker in header", offset)
                }
                let length = Int(buffer[markerAt + 1]) << 8 | Int(buffer[markerAt + 2])
                let end = markerAt + 1 + length
                guard length >= 2, end <= buffer.count else { return unsupported("truncated header", offset) }
                let payload = UnsafeRawBufferPointer(rebasing: buffer[markerAt + 3..<end])
                if marker == 0xDA {
                    guard let layout = parser.layout(startOfScan: payload) else { return unsupported(parser.unsupported ?? "bad scan", offset) }
                    var decoder = JPEGScanDecoder(layout: layout, start: Int64(end))
                    decoder.feed(buffer, at: 0, upTo: Int64(buffer.count))
                    let outcome: JPEGDecodeResult.Outcome = switch decoder.status {
                    case .complete: .complete
                    case .invalid: .invalid
                    default: .truncated
                    }
                    return JPEGDecodeResult(outcome: outcome, mcusDecoded: decoder.mcusDecoded, totalMCUs: layout.totalMCUs,
                                            validUpTo: Int(decoder.validUpTo), restartSequenceOK: decoder.restartSequenceOK,
                                            restartMarkers: decoder.restartMarkers)
                }
                parser.segment(marker: marker, payload: payload)
                if let reason = parser.unsupported { return unsupported(reason, offset) }
                offset = end
            }
        }
    }
}
