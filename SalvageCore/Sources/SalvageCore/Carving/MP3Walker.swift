import Foundation

/// `structure: "mp3"`: walks an MPEG audio stream to its exact end.
///
/// Layout: an optional ID3v2 tag (its syncsafe size, plus a v2.4 footer, plus zero padding), then
/// consecutive MPEG audio frames that keep one version, layer and sample rate, then optionally an
/// APEv2 tag (with its header and footer) and/or a 128-byte ID3v1 `TAG` trailer.
///
/// The end is validated only when the stream's own evidence says it ends there:
/// - at least `minimumFrames` consecutive frames were walked, or exactly the frame count a
///   Xing/Info header in the first frame declares (a mismatch with that count is never validated);
/// - and the stream is closed by an ID3v1/APE trailer, or the bytes after the last frame up to
///   the next sector boundary are zero (file slack). Anything else right after the last frame
///   (non-zero bytes that aren't a frame) is how a fragmented or overwritten stream looks, so
///   the carve ends after the last frame but is partial.
///
/// An ID3 tag not followed by frames falls back to running open-ended (partial), as before.
final class MP3Walker: CarveWalker, @unchecked Sendable {
    static let minimumFrames = 8
    /// Zero bytes skipped between an ID3v2 tag and the first frame.
    static let maxPadding: Int64 = 64 * 1024
    /// Largest APEv2 tag accepted.
    static let maxAPEBytes: Int64 = 16 << 20

    private enum State {
        case id3
        case padding(Int64)
        case frames
        /// An APEv2 header was seen at `framesEnd`; `next` is where its footer must be.
        case apeFooter(framesEnd: Int64, tagEnd: Int64)
        /// After a verified APE tag; an ID3v1 trailer may follow.
        case afterAPE
    }

    let start: Int64
    let sectorSize: Int64
    private var next: Int64
    private var state: State
    private var tagEnd: Int64?
    private var frames = 0
    private var key: Int?
    private var declaredFrames: Int?

    init(start: Int64, sectorSize: Int) {
        self.start = start
        self.sectorSize = Int64(max(sectorSize, 1))
        next = start
        state = .id3
    }

    var retainFrom: Int64 { next }
    var cover: Int64? { next }
    var sizeDerived: Bool { true }

    func absorbs(at position: Int64, weak: Bool, embedded: Bool, trustedMax: Int64) -> Bool {
        guard position < next else { return false }
        switch state {
        case .padding, .apeFooter:
            // Inside a tag whose size was read: cover art and the like are this file's data.
            return weak || (embedded && next - start <= trustedMax)
        case .id3, .frames, .afterAPE:
            // Inside a walked frame: only weak headers (frame syncs) are audio data.
            return weak
        }
    }

    func advance(through limit: Int64, _ w: Window) -> WalkOutcome {
        while true {
            guard next <= limit else { return .paused }
            switch state {
            case .id3:
                guard w.matches(Array("ID3".utf8), at: next) else {
                    state = .frames
                    continue
                }
                guard next <= w.end - 10 else { return .needBytes }
                guard let major = w.byte(at: next + 3), let revision = w.byte(at: next + 4), let flags = w.byte(at: next + 5),
                      (2...4).contains(major), revision != 0xFF else { return .openEnded(.limit) }
                var size: Int64 = 0
                for index in 6..<10 {
                    guard let byte = w.byte(at: next + Int64(index)), byte < 0x80 else { return .openEnded(.limit) }
                    size = size << 7 | Int64(byte)
                }
                let footer: Int64 = major == 4 && flags & 0x10 != 0 ? 10 : 0
                let (end, overflow) = next.addingReportingOverflow(10 + size + footer)
                guard !overflow else { return .end(next, .inconsistent) }
                tagEnd = end
                next = end
                state = .padding(0)

            case .padding(let skipped):
                guard let byte = w.byte(at: next) else { return .needBytes }
                if byte == 0 {
                    guard skipped < Self.maxPadding else { return .openEnded(.limit) }
                    next += 1
                    state = .padding(skipped + 1)
                    continue
                }
                guard next <= w.end - 4 else { return .needBytes }
                // The tag must be followed by audio, or nothing here says where the file ends.
                guard w.mpegFrame(at: next) != nil else { return .openEnded(.limit) }
                state = .frames

            case .frames:
                guard next <= w.end - 4 else { return .needBytes }
                if let frame = w.mpegFrame(at: next), key == nil || frame.key == key {
                    if key == nil {
                        guard let declared = xingFrameCount(at: next, length: frame.length, w) else { return .needBytes }
                        declaredFrames = declared >= 0 ? declared : nil
                        key = frame.key
                    }
                    let (end, overflow) = next.addingReportingOverflow(Int64(frame.length))
                    guard !overflow else { return .end(next, .inconsistent) }
                    frames += 1
                    next = end
                    continue
                }
                if frames == 0 { return .openEnded(.limit) }
                if let outcome = framesEnded(w) { return outcome }

            case .apeFooter(let framesEnd, let apeEnd):
                guard next <= w.end - 32 else { return .needBytes }
                guard isAPE(at: next, header: false, w) else { return .end(framesEnd, .limit) }
                next = apeEnd
                state = .afterAPE

            case .afterAPE:
                if !w.final, next > w.end - 128 { return .needBytes }
                if w.matches(Array("TAG".utf8), at: next), next <= w.end - 128 { return finish(at: next + 128) }
                return finish(at: next)
            }
        }
    }

    /// The frame before `next` is the last one: look for a trailer, else judge the slack after
    /// it. Returns nil when the walk continues into an APE tag.
    private func framesEnded(_ w: Window) -> WalkOutcome? {
        let framesEnd = next
        let (aligned, alignOverflow) = alignUp(framesEnd)
        guard !alignOverflow else { return .end(framesEnd, .inconsistent) }
        if !w.final, framesEnd > w.end - 128 || aligned > w.end { return .needBytes }
        if w.matches(Array("TAG".utf8), at: framesEnd), framesEnd <= w.end - 128 { return finish(at: framesEnd + 128) }
        if isAPE(at: framesEnd, header: true, w), let size = w.readUInt(at: framesEnd + 12, width: 4, endian: .little) {
            // `size` covers the items and the footer, not the header.
            let size = Int64(size)
            guard size >= 32, size <= Self.maxAPEBytes else { return .end(framesEnd, .limit) }
            let (footer, footerOverflow) = framesEnd.addingReportingOverflow(size)
            let (tagEnd, tagOverflow) = footer.addingReportingOverflow(32)
            guard !footerOverflow, !tagOverflow else { return .end(framesEnd, .inconsistent) }
            next = footer
            state = .apeFooter(framesEnd: framesEnd, tagEnd: tagEnd)
            return nil
        }
        guard w.allZero(framesEnd..<aligned), aligned <= w.end || w.final else { return .end(framesEnd, .limit) }
        return finish(at: framesEnd)
    }

    private func finish(at end: Int64) -> WalkOutcome {
        let complete: Bool = if let declaredFrames {
            // Encoders differ on whether the count includes the Xing/Info frame itself.
            frames == declaredFrames || frames == declaredFrames + 1
        } else {
            frames >= Self.minimumFrames
        }
        return .end(end, complete ? .validated : .limit)
    }

    /// An APEv2 header (`header`) or footer at `offset`: preamble, version 1000/2000 and the
    /// header flag bit agreeing.
    private func isAPE(at offset: Int64, header: Bool, _ w: Window) -> Bool {
        guard w.matches(Array("APETAGEX".utf8), at: offset),
              let version = w.readUInt(at: offset + 8, width: 4, endian: .little), version == 1000 || version == 2000,
              let flags = w.readUInt(at: offset + 20, width: 4, endian: .little) else { return false }
        let isHeader = flags & (1 << 29) != 0
        if header { return isHeader && flags & (1 << 31) != 0 }
        return !isHeader
    }

    /// The frame count of a Xing/Info header in the Layer III frame at `offset`: -1 when there is
    /// none, nil when the bytes aren't in the window yet.
    private func xingFrameCount(at offset: Int64, length: Int, _ w: Window) -> Int? {
        guard let b1 = w.byte(at: offset + 1), let b3 = w.byte(at: offset + 3) else { return nil }
        guard b1 >> 1 & 3 == 1 else { return -1 }    // Layer III only
        let mpeg1 = b1 >> 3 & 3 == 3, mono = b3 >> 6 == 3
        let side = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        let at = 4 + (b1 & 1 == 0 ? 2 : 0) + side
        guard length >= at + 12 else { return -1 }
        guard offset + Int64(at + 12) <= w.end else { return w.final ? -1 : nil }
        guard w.matches(Array("Xing".utf8), at: offset + Int64(at)) || w.matches(Array("Info".utf8), at: offset + Int64(at)),
              let flags = w.readUInt(at: offset + Int64(at + 4), width: 4, endian: .big), flags & 1 != 0,
              let count = w.readUInt(at: offset + Int64(at + 8), width: 4, endian: .big), count > 0 else { return -1 }
        return Int(count)
    }

    private func alignUp(_ offset: Int64) -> (Int64, Bool) {
        let remainder = offset % sectorSize
        guard remainder != 0 else { return (offset, false) }
        return offset.addingReportingOverflow(sectorSize - remainder)
    }
}
