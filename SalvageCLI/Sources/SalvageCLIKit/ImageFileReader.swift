import Darwin
import Foundation
import SalvageCore

/// Why a disk image file can't be read as a source.
enum ImageOpenError: Error, Equatable, CustomStringConvertible {
    case cannotOpen(path: String, reason: String)
    /// A device node (or a link to one): devices go through `RawBlockReader` and its safety checks.
    case deviceNode(path: String)
    case notRegularFile(path: String)
    case notReadOnly
    case empty(path: String)
    /// A compressed, sparse or otherwise encoded image whose bytes aren't the disk's bytes.
    case encodedImage(path: String)

    var description: String {
        switch self {
        case .cannotOpen(let path, let reason): "Couldn't open \(path): \(reason)."
        case .deviceNode(let path):
            "\(path) is a device. Name the drive as diskN instead (see `salvage list`), so Salvage can apply its safety checks."
        case .notRegularFile(let path): "\(path) isn't a disk image file."
        case .notReadOnly: "The image wasn't opened read-only, so it was refused."
        case .empty(let path): "\(path) is empty."
        case .encodedImage(let path):
            "\(path) is a compressed or encoded disk image. Make a raw copy first: hdiutil convert \"\(path)\" -format UDTO -o copy (then scan copy.cdr)."
        }
    }
}

/// Reads a raw disk image *file* (a `.img`/`.dd`/`.cdr`, or a read-write `.dmg`) with `pread` on
/// a descriptor opened `O_RDONLY`. Nothing in this type can write: it holds no writable handle,
/// and the descriptor's access mode is verified after the open.
///
/// A UDIF trailer ("koly" block in the last 512 bytes) is not part of the disk; an image with one
/// is accepted only when the trailer says the data fork is the raw disk starting at byte 0 and
/// it carries no block map (UDRW). Compressed images (UDZO, ...) are refused, never misread.
final class ImageFileReader: BlockReader, @unchecked Sendable {
    let sizeBytes: Int64
    let path: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(path: String) throws {
        self.path = path
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ImageOpenError.cannotOpen(path: path, reason: String(cString: strerror(errno))) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw ImageOpenError.notRegularFile(path: path) }
        let kind = info.st_mode & S_IFMT
        guard kind != S_IFCHR, kind != S_IFBLK else { Darwin.close(fd); throw ImageOpenError.deviceNode(path: path) }
        guard kind == S_IFREG else { Darwin.close(fd); throw ImageOpenError.notRegularFile(path: path) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY else { Darwin.close(fd); throw ImageOpenError.notReadOnly }
        var size = Int64(info.st_size)
        guard size > 0 else { Darwin.close(fd); throw ImageOpenError.empty(path: path) }
        if size >= 1024, let trailer = Self.pread(fd, at: size - 512, count: 512), trailer.prefix(4) == Data("koly".utf8) {
            guard let dataLength = Self.rawDataForkLength(trailer: trailer, fileSize: size) else {
                Darwin.close(fd); throw ImageOpenError.encodedImage(path: path)
            }
            size = dataLength
        }
        descriptor = fd
        sizeBytes = size
    }

    deinit { close() }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(descriptor)
        }
    }

    /// The UDIF trailer's data fork length when it describes a raw image (data fork at offset 0
    /// running up to the trailer, no XML block map); nil otherwise. Fields are big-endian.
    static func rawDataForkLength(trailer: Data, fileSize: Int64) -> Int64? {
        guard trailer.count == 512 else { return nil }
        let bytes = [UInt8](trailer)
        func u64(_ offset: Int) -> UInt64 { bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) } }
        let dataForkOffset = u64(0x18), dataForkLength = u64(0x20), xmlOffset = u64(0xD8), xmlLength = u64(0xE0)
        guard dataForkOffset == 0, xmlOffset == 0, xmlLength == 0,
              dataForkLength > 0, dataForkLength == UInt64(fileSize - 512) else { return nil }
        return Int64(dataForkLength)
    }

    private static func pread(_ fd: Int32, at offset: Int64, count: Int) -> Data? {
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, count, offset) }
        return read == count ? data : nil
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, count <= 64 * 1024 * 1024, offset <= sizeBytes,
              Int64(count) <= sizeBytes - offset else {
            throw ScanError.io("Read outside the image.")
        }
        if count == 0 { return Data() }
        var data = Data(count: count)
        let failure: ScanError? = lock.withLock {
            guard !closed else { return ScanError.io("The image is closed.") }
            return data.withUnsafeMutableBytes { raw -> ScanError? in
                guard let base = raw.baseAddress else { return ScanError.io("Couldn't allocate a read buffer.") }
                var done = 0
                while done < count {
                    let n = Darwin.pread(descriptor, base + done, count - done, offset + Int64(done))
                    if n < 0 { if errno == EINTR { continue }; return ScanError.io(String(cString: strerror(errno))) }
                    if n == 0 { return ScanError.io("Short read: the image ended early.") }
                    done += n
                }
                return nil
            }
        }
        if let failure { throw failure }
        return data
    }
}
