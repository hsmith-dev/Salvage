import Foundation

/// What a structure walker reports after advancing.
enum WalkOutcome {
    /// The next step starts past the `through` offset it was given.
    case paused
    /// The next step needs bytes past the window; at the end of an extent the carve is cut there.
    case needBytes
    /// The structure says the file ends at this device offset, for this reason.
    case end(Int64, SignatureCarver.Cut)
    /// The walk can't find the end: the carve falls back to running to a limit.
    case openEnded(SignatureCarver.Cut)
}

/// A format walker for a `structure` signature whose state is too large or too irregular for the
/// engine's own phases (MP3 frames, the OLE2 allocation table, a DEFLATE stream).
///
/// Contract with `SignatureCarver`:
/// - The walker only reads bytes inside the window it is handed and never asks for bytes before
///   `retainFrom` once it has returned: the engine keeps the carry from there.
/// - `advance(through:)` starts no step whose first byte lies past `through` (the next header
///   position not yet examined, or the carve's claim/size bound), so a header the engine hasn't
///   evaluated can still cut the carve. A step that started in time may read past it.
/// - Every offset computation is checked; an overflow ends the walk as inconsistent.
/// - Work is proportional to the bytes the walk consumes, and each walker caps its own state.
///
/// Walkers are mutable reference types confined to the `SignatureCarver` actor that created them
/// (they live only in its open carves), which is why they are `@unchecked Sendable`.
protocol CarveWalker: AnyObject, Sendable {
    /// Earliest device offset the walker still needs to read.
    var retainFrom: Int64 { get }
    /// Bytes before this offset are known to belong to the file; nil while the walk can't tell.
    var cover: Int64? { get }
    /// The end comes from counting records, not from a checksum, so it is only trusted up to the
    /// signature's `trustedMaxBytes`.
    var sizeDerived: Bool { get }
    func advance(through limit: Int64, _ window: Window) -> WalkOutcome
    /// Whether headers matched at `position` are this file's own data rather than a new file.
    func absorbs(at position: Int64, weak: Bool, embedded: Bool, trustedMax: Int64) -> Bool
}

extension Window {
    /// Whether `bytes` sit at `offset` (false when they aren't all in the window).
    func matches(_ bytes: [UInt8], at offset: Int64) -> Bool {
        guard offset >= start, offset <= end - Int64(bytes.count) else { return false }
        let base = index(offset)
        for (position, byte) in bytes.enumerated() where buffer[base + position] != byte { return false }
        return true
    }

    /// Whether every byte in `range` (clamped to the window) is zero.
    func allZero(_ range: Range<Int64>) -> Bool {
        let lower = max(range.lowerBound, start), upper = min(range.upperBound, end)
        guard lower < upper else { return true }
        for position in index(lower)..<index(upper) where buffer[position] != 0 { return false }
        return true
    }
}
