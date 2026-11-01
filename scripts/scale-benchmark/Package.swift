// swift-tools-version: 6.0
import PackageDescription

// Scale benchmark tools (docs/PERFORMANCE.md). Not part of the app or the CLI.
//   make-ntfs-image  writes a synthetic MBR disk image (sparse file) with two NTFS volumes,
//                    hundreds of thousands of MFT records in deep folders, and a carving zone.
//   trace-scan       runs ScanSession over an image file read-only and reports every read
//                    (count, small reads, seeks), memory per found file, and a modelled HDD time.
let package = Package(
    name: "scale-benchmark",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../SalvageCore"), .package(path: "../../SalvageDiskIO")],
    targets: [
        // A single-file script: top-level state, so Swift 5 mode.
        .executableTarget(name: "make-ntfs-image", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "trace-scan",
                          dependencies: [.product(name: "SalvageCore", package: "SalvageCore"),
                                         .product(name: "SalvageDiskIO", package: "SalvageDiskIO")],
                          swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
