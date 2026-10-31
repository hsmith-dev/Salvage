import Foundation

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
