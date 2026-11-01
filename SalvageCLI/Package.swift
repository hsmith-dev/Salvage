// swift-tools-version: 6.0
import PackageDescription

// SalvageCLI -- the `salvage` command-line tool (spec-tech-batch-6 §C).
//
// A driving adapter beside the app: it uses SalvageCore (scan, content reads) and SalvageDiskIO
// (device tree, RawBlockReader with its boot-disk refusal and helper fallback, destination
// safety) by path, and never imports DiskArbitration itself (AD-1/AD-9). Local dependencies
// only: scripts/check-no-network.sh refuses any remote package and scans these sources for
// network APIs.
let package = Package(
    name: "SalvageCLI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "salvage", targets: ["salvage"])
    ],
    dependencies: [
        .package(path: "../SalvageCore"),
        .package(path: "../SalvageDiskIO")
    ],
    targets: [
        // Everything testable: argument parsing, commands, the image-file reader, output.
        .target(
            name: "SalvageCLIKit",
            dependencies: [
                .product(name: "SalvageCore", package: "SalvageCore"),
                .product(name: "SalvageDiskIO", package: "SalvageDiskIO")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "salvage",
            dependencies: ["SalvageCLIKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SalvageCLITests",
            // `salvage` is listed so the binary is built for the end-to-end process tests.
            dependencies: ["SalvageCLIKit", "salvage"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
