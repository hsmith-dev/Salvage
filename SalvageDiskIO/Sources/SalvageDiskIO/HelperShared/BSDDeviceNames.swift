import Foundation

// Ported, close to verbatim, from Story 1.2's spike harness
// (scripts/spike-raw-device-access/Sources/spike-raw-device-access/BSDDeviceNames.swift). That
// logic is unit-tested and was hardened through a real safety-focused review pass -- re-deriving
// it here from scratch would risk reintroducing the same fail-open bugs that review caught (see
// spec-1-3's Resolved decision). Adapted only to live in SalvageDiskIO rather than the spike's
// CLI-only target; the logic itself is unchanged.
//
// Story 1.12: this file lives in `HelperShared/` because the privileged `SalvageHelper` target
// compiles it too, so the helper re-validates names with exactly the same code as the app. Keep
// it Foundation-only and free of SalvageCore/DiskArbitration references.

/// Extracts the whole-disk BSD name (e.g. "disk6") from a raw or buffered device path or BSD
/// name (e.g. "/dev/rdisk6", "/dev/rdisk6s1", "/dev/disk6", "disk0s2"). Returns `nil` -- never a
/// best-guess substitute -- if the input doesn't actually have the expected "[r]disk<N>[...]"
/// shape, so a malformed or unrelated path can never silently resolve to the wrong disk number.
func wholeDiskBSDName(fromDevicePath path: String) -> String? {
    let fileName = (path as NSString).lastPathComponent
    let bsdBase = fileName.hasPrefix("r") ? String(fileName.dropFirst()) : fileName
    guard bsdBase.hasPrefix("disk") else { return nil }
    let digits = bsdBase.dropFirst("disk".count).prefix { $0.isNumber }
    guard !digits.isEmpty else { return nil }
    return "disk\(digits)"
}

/// Strict whole-disk BSD name check shared by `RawBlockReader` and the privileged helper, which
/// compiles this file directly: exactly "disk" followed by 1-6 ASCII digits with no leading zero
/// (other than "disk0") and nothing else. Unlike `wholeDiskBSDName(fromDevicePath:)`, this never
/// extracts a name from a longer string; anything that isn't already a whole-disk name is refused.
func isWholeDiskBSDName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    let prefix = Array("disk".utf8)
    guard bytes.count > prefix.count, bytes.count <= prefix.count + 6,
          bytes.starts(with: prefix) else { return false }
    let digits = bytes.dropFirst(prefix.count)
    guard digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return false }
    return digits.count == 1 || digits.first != UInt8(ascii: "0")
}
